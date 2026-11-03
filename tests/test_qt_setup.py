import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class QtSetupTests(unittest.TestCase):
    def test_download_retry_module_selection_and_reuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / '.tools/aqtinstall/bin'
            tools.mkdir(parents=True)
            python = tools / 'python'
            python.write_text('''#!/bin/bash
if [ "$1" = -c ]; then exit 0; fi
if [ "$3" = list-qt ]; then
    echo "qtwebengine qtwebchannel qtpositioning qtsvg qtshadertools qtimageformats qtcharts qtgraphs qt3d"
    exit 0
fi
if [ "$3" = install-qt ]; then
    echo "$*" >> "$LIBRARIES_ROOT/attempts"
    if [ ! -f "$LIBRARIES_ROOT/failed-once" ]; then touch "$LIBRARIES_ROOT/failed-once"; exit 1; fi
    mkdir -p "$QT_DIR/bin" "$QT_DIR/lib/cmake/Qt6"
    touch "$QT_DIR/bin/macdeployqt" "$QT_DIR/lib/cmake/Qt6/Qt6Config.cmake"
    chmod +x "$QT_DIR/bin/macdeployqt"
    for framework in QtCore QtGui QtWidgets QtConcurrent; do
        mkdir -p "$QT_DIR/lib/$framework.framework/Versions/A"
        touch "$QT_DIR/lib/$framework.framework/Versions/A/$framework"
    done
    for component in Qt6Concurrent Qt6WebEngineCore Qt6WebEngineWidgets; do
        mkdir -p "$QT_DIR/lib/cmake/$component"
        touch "$QT_DIR/lib/cmake/$component/${component}Config.cmake"
    done
    exit 0
fi
exit 99
''')
            python.chmod(0o755)
            for name, body in [('lipo', 'exit 0'), ('sleep', 'exit 0'), ('uname', 'echo Darwin')]:
                script = tools / name
                script.write_text('#!/bin/bash\n' + body + '\n')
                script.chmod(0o755)
            env = dict(os.environ, LIBRARIES_ROOT=str(root), QT_DIR=str(root / 'qt/6.10.3/macos'),
                       QT_VERSION='6.10.3', DEPENDENCY_BUILD_MODE='if-missing', PATH=str(tools) + ':' + os.environ['PATH'])
            command = ['bash', str(ROOT / 'scripts/dependencies/build_qt_universal.sh')]
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            attempts = (root / 'attempts').read_text().splitlines()
            self.assertEqual(len(attempts), 2)
            self.assertIn('qtwebengine', attempts[-1])
            self.assertNotIn('qtcharts', attempts[-1])
            self.assertNotIn('qt3d', attempts[-1])
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len((root / 'attempts').read_text().splitlines()), 2)


if __name__ == '__main__':
    unittest.main()
