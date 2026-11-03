import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dependency_manager', ROOT / 'scripts/dependencies/dependency_manager.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class DependencyManagerTests(unittest.TestCase):
    def test_nonexecutable_generated_script_receives_recipe_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'dependencies'
            scripts.mkdir()
            output = root / 'installed'
            script = scripts / 'build_test.sh'
            script.write_text('''#!/bin/bash
set -eu
[ "$DEPENDENCY_NAME" = test ]
[ "$DEPENDENCY_VERSION" = v1 ]
[ "$DEPENDENCY_LINKAGE" = static ]
[ "$DEPENDENCY_RECIPE_JSON" = '{"buildSystem": "cmake"}' ]
touch "$TEST_OUTPUT"
''')
            script.chmod(0o644)
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'schemaVersion': 1, 'dependencies': [
                {'name': 'test', 'version': 'v1', 'script': script.name, 'linkage': 'static',
                 'artifacts': ['installed'], 'requires': [], 'recipe': {'buildSystem': 'cmake'}}]}))
            with patch.object(manager, 'SCRIPT_DIR', scripts), patch.object(manager, 'SCRIPTS_ROOT', root), patch.object(manager, 'LIBRARIES_ROOT', root), \
                 patch('sys.argv', ['manager', '--manifest', str(manifest)]), \
                 patch.dict('os.environ', {'TEST_OUTPUT': str(output), 'ARCHS': ''}):
                self.assertEqual(manager.main(), 0)
            self.assertTrue(output.exists())
