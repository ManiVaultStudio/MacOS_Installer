import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from instance_control import discover,validate_shutdown

class InstanceControlTests(unittest.TestCase):
    def test_last_instance_and_busy_instance_are_protected(self):
        one=[{'responding':True}]
        with self.assertRaisesRegex(ValueError,'last app instance'):validate_shutdown(one,12,12,False)
        with self.assertRaisesRegex(ValueError,'running build'):validate_shutdown(one*2,12,12,True)
        with self.assertRaisesRegex(ValueError,'process changed'):validate_shutdown(one*2,11,12,False)
        validate_shutdown(one*2,12,12,False)

    def test_discovery_verifies_identity_and_ports_in_paths_with_spaces(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'Workspace One'; root.mkdir()
            other=Path(directory)/'Workspace Two';other.mkdir()
            for folder,pid,port in [(root,12,58001),(other,13,58002)]:
                (folder/'.installer_app.json').write_text(json.dumps({'pid':pid,'port':port}))
            output=f'12 /python {root}/installer_app.py --no-browser\n13 /python {other}/installer_app.py\n99 /python unrelated.py\n'
            def health(url,**kwargs):
                return io.StringIO(json.dumps({'pid':12 if '58001' in url else 13,'instanceControl':1,'busy':'58002' in url}))
            with patch('instance_control.subprocess.run',return_value=subprocess.CompletedProcess([],0,stdout=output)),patch('instance_control.urllib.request.urlopen',side_effect=health):
                result=discover(root,12)
            self.assertEqual(len(result),2)
            self.assertTrue(result[0]['canStop'])
            self.assertFalse(result[1]['canStop'])
            self.assertEqual(result[1]['port'],58002)

    def test_recycled_pid_is_not_counted_as_healthy(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'.installer_app.json').write_text(json.dumps({'pid':12,'port':58001}))
            with patch('instance_control.subprocess.run',return_value=subprocess.CompletedProcess([],0,stdout='')),patch('instance_control.urllib.request.urlopen',return_value=io.StringIO('{"pid":999}')):
                result=discover(root,12)
            self.assertFalse(result[0]['responding'])
            self.assertFalse(result[0]['canStop'])


class PreviewModeTests(unittest.TestCase):
    def test_preview_does_not_change_saved_release_version(self):
        import installer_app as app
        from unittest.mock import MagicMock
        payload={'action':'full','profile':'example','version':'9.9.9','jobs':0,'dry':True}
        handler=object.__new__(app.Handler)
        body=json.dumps(payload).encode()
        handler.path='/api/create-installer';handler.rfile=io.BytesIO(body)
        handler.headers={'Content-Length':str(len(body))};handler.send_json=MagicMock()
        with patch.object(app,'external_live_run',return_value=None),patch.dict(app.APP_STATE,{'process':None}),patch.object(app,'update_project_settings') as update,patch.object(app,'start_run') as start:
            handler.do_POST()
        update.assert_not_called()
        start.assert_called_once_with(payload)
        handler.send_json.assert_called_once_with({'ok':True})
