import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import installer_app as app


class InstanceStatusTests(unittest.TestCase):
    def test_status_does_not_load_project_database(self):
        info={'pid':1234,'port':58001,'url':'http://127.0.0.1:58001','responding':True,'process_alive':True}
        output=io.StringIO()
        with patch.object(sys,'argv',['installer_app.py','--status']), patch.object(app,'inspect_instance',return_value=info), patch.object(app,'open_database',side_effect=AssertionError('status must not load the database')), contextlib.redirect_stdout(output):
            app.main()
        self.assertIn('Port: 58001',output.getvalue())
        self.assertIn('Process ID: 1234',output.getvalue())
        self.assertIn('Health: responding',output.getvalue())

    def test_held_lock_reports_port_and_action_without_traceback(self):
        info={'pid':1234,'port':58001,'url':'http://127.0.0.1:58001','responding':False,'process_alive':True}
        output=io.StringIO()
        with tempfile.TemporaryDirectory() as temp, patch.object(app,'INSTANCE_LOCK_FILE',Path(temp)/'lock'), patch.object(app.fcntl,'flock',side_effect=BlockingIOError), patch.object(app,'inspect_instance',return_value=info), patch.object(app.time,'monotonic',side_effect=[0,1,10]), patch.object(app.time,'sleep'), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                app.acquire_single_instance()
        self.assertIn('Port: 58001',output.getvalue())
        self.assertIn('lsof -nP -iTCP:58001',output.getvalue())
        self.assertIn('--status',str(stopped.exception))
        self.assertNotIn('Traceback',output.getvalue())

    def test_health_check_does_not_depend_on_project_configuration(self):
        handler=object.__new__(app.Handler)
        handler.path='/api/health'
        handler.server=MagicMock(server_address=('127.0.0.1',58001))
        handler.send_json=MagicMock()
        with patch.object(app,'open_database',side_effect=AssertionError('health must not load the database')):
            handler.do_GET()
        result=handler.send_json.call_args.args[0]
        self.assertTrue(result['ok'])
        self.assertEqual(result['port'],58001)


if __name__=='__main__':unittest.main()
