import importlib.util
import tempfile
import unittest
import os
from pathlib import Path
from build_performance import automatic_jobs
from installer_app import validate_build_settings

spec = importlib.util.spec_from_file_location('source_timestamps', Path(__file__).resolve().parents[1] / 'scripts/lib/source_timestamps.py')
timestamps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timestamps)

class BuildPerformanceTests(unittest.TestCase):
    def test_auto_parallelism_respects_memory_and_cpu(self):
        self.assertEqual(automatic_jobs(16, 8*1024**3), 2)
        self.assertEqual(automatic_jobs(4, 64*1024**3), 4)
        self.assertEqual(automatic_jobs(32, 128*1024**3), 8)
        self.assertEqual(automatic_jobs(8, 2*1024**3), 1)

    def test_auto_and_defaults_valid_for_both_build_endpoints(self):
        self.assertEqual(validate_build_settings({}), (0,'if-missing'))
        self.assertEqual(validate_build_settings({'jobs':0,'mode':'skip'}),(0,'skip'))
        for bad in [None, 'bad', -1, 9, True, 1.5]:
            with self.assertRaises(ValueError): validate_build_settings({'jobs':bad})
        with self.assertRaises(ValueError): validate_build_settings({'mode':'invalid'})

    def test_unchanged_overlay_does_not_trigger_recompilation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)/'source'; root.mkdir()
            file = root/'source.cpp'; file.write_text('original')
            original = file.stat().st_mtime_ns
            state = Path(directory)/'snapshot.json'
            timestamps.begin(root,state)
            file.write_text('original')
            timestamps.finish(root,state)
            self.assertEqual(file.stat().st_mtime_ns,original)
            timestamps.begin(root,state)
            file.write_text('changed')
            os.utime(file,ns=(original,original))
            timestamps.finish(root,state)
            self.assertGreater(file.stat().st_mtime_ns,original)
            self.assertFalse(state.exists())

    def test_repeat_source_preparation_reuses_fingerprints(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'source';root.mkdir()
            file=root/'source.cpp';file.write_text('unchanged source')
            state=Path(directory)/'snapshot.json'
            timestamps.begin(root,state);timestamps.finish(root,state)
            with patch.object(timestamps,'digest',wraps=timestamps.digest) as digest:
                timestamps.begin(root,state);timestamps.finish(root,state)
                digest.assert_not_called()
            before=file.stat().st_mtime_ns
            file.write_text('changed same mtime')
            os.utime(file,ns=(before,before))
            with patch.object(timestamps,'digest',wraps=timestamps.digest) as digest:
                timestamps.begin(root,state)
                self.assertGreater(digest.call_count,0)
                self.assertGreater(file.stat().st_mtime_ns,before)
