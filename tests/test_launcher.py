import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LauncherTests(unittest.TestCase):
    def test_old_python_explains_required_version_before_install(self):
        with tempfile.TemporaryDirectory() as folder:
            old = Path(folder)/'old-python'
            old.write_text('#!/bin/bash\nexit 1\n'); old.chmod(0o755)
            result = subprocess.run(['bash',str(ROOT/'Start.command'),'--status'],env=dict(os.environ,PYTHON=str(old)),capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Python 3.10 or newer',result.stdout)

    def test_fresh_runtime_and_retry_use_isolated_environment(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); launcher=root/'Start.command';launcher.write_text((ROOT/'Start.command').read_text())
            (root/'requirements.txt').write_text('example\n')
            python=root/'bootstrap-python'
            python.write_text('''#!/bin/bash
if [ "$1" = -c ]; then exit 0; fi
if [ "$1" = -m ] && [ "$2" = venv ]; then
 mkdir -p "$3/bin"
 cp "$FAKE_RUNTIME" "$3/bin/python"
 chmod +x "$3/bin/python"
 exit 0
fi
exit 99
'''); python.chmod(0o755)
            runtime=root/'runtime-template'
            runtime.write_text('''#!/bin/bash
if [ "$1" = -c ]; then
 case "$2" in *openpyxl*) test -f "$SETUP_ROOT/installed";; *) exit 0;; esac
 exit $?
fi
if [ "$1" = -m ] && [ "$2" = pip ]; then
 echo attempt >> "$SETUP_ROOT/attempts"
 if [ ! -f "$SETUP_ROOT/retry" ]; then touch "$SETUP_ROOT/retry"; exit 1; fi
 touch "$SETUP_ROOT/installed"; exit 0
fi
echo "launched $*"
''');runtime.chmod(0o755)
            env=dict(os.environ,PYTHON=str(python),FAKE_RUNTIME=str(runtime),SETUP_ROOT=str(root))
            first=subprocess.run(['bash',str(launcher),'--status'],env=env,capture_output=True,text=True)
            self.assertNotEqual(first.returncode,0)
            self.assertIn('reopen Start.command to retry',first.stdout)
            second=subprocess.run(['bash',str(launcher),'--status'],env=env,capture_output=True,text=True)
            self.assertEqual(second.returncode,0,second.stderr)
            self.assertIn('--status',second.stdout)
            self.assertEqual(len((root/'attempts').read_text().splitlines()),2)
