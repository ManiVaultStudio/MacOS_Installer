import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('workflow_events_engine',Path(__file__).resolve().parents[1]/'scripts/workflow/installer_engine.py')
engine=importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

class WorkflowEventsTests(unittest.TestCase):
    def test_operation_logs_keyword_and_success_markers(self):
        logs=[]
        def operation(*,logs): logs.append(('INFO','test','operation'))
        with contextlib.redirect_stdout(io.StringIO()): engine.workflow_stage(1,logs,operation,logs=logs)
        self.assertIn('[studio-stage:1:running]',logs[0][2])
        self.assertIn('[studio-stage:1:completed]',logs[-1][2])

    def test_failure_is_preserved_and_recorded(self):
        logs=[]
        def fail(): raise RuntimeError('failed fixture')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError,'failed fixture'):
            engine.workflow_stage(4,logs,fail)
        self.assertIn('[studio-stage:4:failed]',logs[-1][2])

    def test_nonzero_diagnosis_marks_failure(self):
        logs=[]
        with contextlib.redirect_stdout(io.StringIO()):
            result=engine.workflow_stage(3,logs,lambda:1)
        self.assertEqual(result,1)
        self.assertIn('[studio-stage:3:failed]',logs[-1][2])
