import unittest
from unittest.mock import MagicMock, patch
import installer_app as app

class LightweightStateTests(unittest.TestCase):
    def request(self,path):
        handler=object.__new__(app.Handler);handler.path=path;handler.send_json=MagicMock()
        rows=lambda name: [{'Run ID':'r1','Profile ID':'p','Status':'succeeded'}] if name=='Runs' else []
        with patch.dict(app.APP_STATE,{'process':None,'run_id':''}),patch.object(app,'external_live_run',return_value=None),patch.object(app,'read_rows',side_effect=rows),patch.object(app,'read_settings',return_value={}),patch.object(app,'dependency_catalog',return_value={'items':[]}),patch.object(app,'evaluate_readiness',return_value=[]),patch.object(app,'logs_for_run',return_value=[{'Message':'test'}]) as logs,patch.object(app,'log_revision',return_value='rev1'):
            handler.handle_get()
        return handler.send_json.call_args.args[0],logs

    def test_other_views_never_load_log_history(self):
        result,logs=self.request('/api/state?logs=0')
        logs.assert_not_called()
        self.assertNotIn('logs',result)
        self.assertIn('projects',result)

    def test_matching_revision_does_not_resend_logs(self):
        result,logs=self.request('/api/state?logs=1&run=r1&logRevision=rev1')
        logs.assert_not_called()
        self.assertNotIn('logs',result)
        self.assertEqual(result['logRevision'],'rev1')

    def test_first_activity_request_includes_history(self):
        result,logs=self.request('/api/state?logs=1&run=r1')
        logs.assert_called_once_with('r1')
        self.assertEqual(len(result['logs']),1)
