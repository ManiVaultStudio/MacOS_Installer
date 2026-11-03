import contextlib
import importlib.util
import io
import json
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import installer_app as app
from database_io import load_database, atomic_save_workbook, encode_table, _write_json, save_source_pins
from dependency_actions import uninstall, output_paths
from dependency_config import entries_from_rows, save_receipt, version_environment, enabled_closure
from project_dependencies import evaluate, update_requirements
import test_management as fixtures
ROOT = fixtures.ROOT

spec = importlib.util.spec_from_file_location('engine_test', ROOT / 'scripts/workflow/installer_engine.py')
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class LifecycleTests(unittest.TestCase):
    setUp = fixtures.ManagementTests.setUp
    def add_test_library(self):
        (self.root / 'scripts/dependencies').mkdir(exist_ok=True)
        app.add_entry({'kind': 'dependency', 'values': {'Name': 'test-library', 'Version / commit': '1.0',
            'Enabled': 'true', 'Linkage': 'static', 'Build Script': 'GENERIC',
            'Source URL': 'https://github.com/example/test-library', 'Artifacts JSON': '["libraries/test-library/install/libtest.a"]',
            'Runtime Files JSON': '[]', 'Requires JSON': '[]', 'Recipe JSON': '{}',
            'Projects': json.dumps([app.read_rows('Projects')[0]['Profile ID']])}})
        path = self.root / 'libraries/test-library/install/libtest.a'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'test output')
        return path

    def readiness(self):
        return evaluate(app.read_rows('Projects'), app.read_rows('ProjectDependencies'), app.dependency_catalog()['items'])

    def test_uninstall_and_reinstall_update_affected_project(self):
        output = self.add_test_library()
        profile = app.read_rows('Projects')[0]['Profile ID']
        catalog = app.dependency_catalog()['items']
        item = next(item for item in catalog if item['name'] == 'test-library')
        self.assertEqual([p['id'] for p in item['projects']], [profile])
        entries = entries_from_rows(app.read_rows('Dependencies'))
        with contextlib.redirect_stdout(io.StringIO()):
            recovery = uninstall(self.root, 'test-library', 'recipe', entries, [])
        self.assertFalse(output.exists())
        self.assertTrue((recovery / 'restore.json').exists())
        status = next(p for p in self.readiness() if p['Profile ID'] == profile)
        self.assertIn('test-library', [d['name'] for d in status['Missing dependencies']])
        output.parent.mkdir(exist_ok=True)
        output.write_bytes(b'reinstalled')
        item = next(e for e in entries if e['name'] == 'test-library')
        save_receipt(self.root / 'libraries', item, entries)
        status = next(p for p in self.readiness() if p['Profile ID'] == profile)
        self.assertNotIn('test-library', [d['name'] for d in status['Missing dependencies']])

    def test_remove_then_readd_preserves_project_requirement(self):
        self.add_test_library()
        required_before = [r for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'test-library']
        row = next(r for r in app.read_rows('Dependencies') if r['Name'] == 'test-library')
        app.remove_entry({'kind': 'dependency', 'values': {'Name': 'test-library'}})
        self.assertTrue(any(d['name'] == 'test-library' and d['reason'] == 'Not registered' for p in self.readiness() for d in p['Missing dependencies']))
        app.add_entry({'kind': 'dependency', 'values': {**row, 'Projects': '[]'}})
        self.assertEqual(required_before, [r for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'test-library'])

    def test_version_policy_keep_then_update(self):
        self.add_test_library()
        app.update_build_dependency({'Name': 'test-library', 'Version / commit': '2.0', 'Update projects': 'false'})
        self.assertTrue(all(r['Version'] == '1.0' for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'test-library'))
        self.assertTrue(any(d['reason'] == 'Version mismatch' for p in self.readiness() for d in p['Missing dependencies'] if d['name'] == 'test-library'))
        # A full settings save also contains project assignments; keeping versions must still work.
        ids = [r['Profile ID'] for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'test-library']
        app.update_build_dependency({'Name': 'test-library', 'Version / commit': '2.1', 'Projects': json.dumps(ids), 'Update projects': 'false'})
        self.assertTrue(all(r['Version'] == '1.0' for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'test-library'))
        app.update_build_dependency({'Name': 'test-library', 'Version / commit': '3.0', 'Update projects': 'true'})
        self.assertTrue(all(r['Version'] == '3.0' for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'test-library'))
        saved = next(r for r in app.read_rows('Dependencies') if r['Name'] == 'test-library')
        self.assertEqual(json.loads(saved['Recipe JSON'])['source']['ref'], '3.0')

    def test_partial_project_version_preserves_other_settings(self):
        row = app.read_rows('Projects')[0]
        profile = row['Profile ID']
        existing_file = self.profiles / (profile + '.env')
        existing_file.write_text('CUSTOM_VALUE=keep\nAPP_VERSION=1.0.0\n')
        app.update_project_settings({'Profile ID': profile, 'App version': '9.8.7'})
        saved = next(r for r in app.read_rows('Projects') if r['Profile ID'] == profile)
        self.assertEqual(saved['App version'], '9.8.7')
        for field in ['Architectures', 'Build type', 'Source root', 'Qt version']:
            self.assertEqual(saved[field], row[field])
        self.assertIn('CUSTOM_VALUE=keep', existing_file.read_text())
        self.assertIn('APP_VERSION=9.8.7', existing_file.read_text())

    def test_source_edit_preserves_patch_and_can_keep_project_version(self):
        profile = app.read_rows('Projects')[0]['Profile ID']
        initial = {'dependencies': [{'name': 'sample', 'source': 'sample-v1', 'version': 'v1',
            'version_file': '.installer-version', 'sourceUrl': 'https://github.com/example/sample',
            'patch_file': 'patches/sample.patch', 'required': True}]}
        book = load_database(self.db)
        update_requirements(book, 'sample', 'pin', 'v1', profiles=[profile])
        save_source_pins(book, self.db, initial)
        app.save_dependency_pin({'Name': 'sample', 'Version': 'v2', 'Source folder': 'sample-v1',
            'Integration': 'FetchContent', 'Update projects': 'false'})
        saved = json.loads((self.db.parent / 'source_pins.json').read_text())['dependencies'][0]
        self.assertEqual(saved['source'], 'sample-v2')
        self.assertEqual(saved['patch_file'], 'patches/sample.patch')
        self.assertEqual(next(r['Version'] for r in app.read_rows('ProjectDependencies') if r['Dependency'] == 'sample'), 'v1')
        self.assertFalse((self.root / 'libraries/sample-v2').exists(), 'Saving a source should not download it')

    def test_install_operation_is_global_and_validates_jobs(self):
        self.add_test_library()
        state = {'process': None, 'run_id': '', 'lock': threading.RLock()}
        process = MagicMock()
        process.poll.return_value = None
        with patch.object(app, 'APP_STATE', state), patch.object(app.subprocess, 'Popen', return_value=process) as spawn, patch.object(app.threading, 'Thread'), patch.object(app, 'external_live_run', return_value=None):
            app.start_run({'action': 'install-dependency', 'profile': 'not-a-project', 'name': 'test-library', 'kind': 'recipe', 'jobs': 1})
            command = spawn.call_args.args[0]
            self.assertEqual(command[3], 'workspace')
            self.assertIn('--jobs', command)
            self.assertEqual(command[command.index('--jobs')+1], '1')
            with self.assertRaises(ValueError):
                app.start_run({'action': 'install-dependency', 'name': 'test-library', 'kind': 'recipe', 'jobs': 99})

    def test_killed_engine_monitor_records_specific_diagnosis(self):
        process = MagicMock()
        process.stdout = io.StringIO('')
        process.wait.return_value = -9
        process.poll.return_value = -9
        state = {'process': process, 'run_id': 'run-killed', 'profile': 'workspace', 'action': 'install-dependency',
                 'started': '2026-11-03T12:00:00+00:00', 'output': ['building sample'], 'lock': threading.RLock()}
        with patch.object(app, 'APP_STATE', state), patch.object(app, 'read_rows', return_value=[{'Run ID':'run-killed','Status':'running'}]), patch.object(app, 'mark_run_interrupted') as mark:
            app.run_engine({})
            self.assertIn('exit code -9', mark.call_args.args[1])
            self.assertIn('Low memory', mark.call_args.args[1])
            self.assertEqual(state['status'], 'interrupted')

    def test_engine_records_termination_and_preserves_full_log(self):
        deps_dir = self.root / 'scripts/dependencies'
        deps_dir.mkdir(exist_ok=True)
        for row in app.read_rows('Dependencies'):
            (deps_dir / row['Build Script']).write_text('#!/bin/bash\n')
        profile = app.read_rows('Projects')[0]['Profile ID']
        with patch.object(engine, 'ROOT', self.root), patch.object(engine, 'DB', self.db), patch.object(engine, 'SCRIPTS', self.root/'scripts'), patch.object(engine.signal, 'signal'), patch.object(engine, 'run_logged', side_effect=SystemExit(143)), patch.object(sys, 'argv', ['engine','dependencies',profile,'--run-id','signal-test']), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(engine.main(), 143)
        run = next(r for r in app.read_rows('Runs') if r['Run ID'] == 'signal-test')
        self.assertEqual(run['Status'], 'interrupted')
        self.assertIn('143', run['Summary'])
        self.assertTrue((self.db.parent / 'local/run_output/signal-test.log').exists())
        self.assertFalse((self.root / '.installer_runtime/signal-test').exists())

    def test_summary_memory_is_bounded(self):
        logs = engine.RunLogs()
        for number in range(10000): logs.append(('INFO','build',str(number)))
        self.assertEqual(len(logs),4000)
        self.assertEqual(logs[-1][2],'9999')
        self.assertEqual(len(logs + [('ERROR','end','failure')]),4001)

    def test_transaction_recovery_finishes_related_files(self):
        load_database(self.db)
        projects = json.loads(self.db.with_name('projects.json').read_text())
        projects['records'][0]['App version'] = '7.7.7'
        requirements = json.loads(self.db.with_name('project_dependencies.json').read_text())
        requirements['records'][0]['Version'] = 'test-version'
        _write_json(self.db.parent / '.transaction.json', {'projects.json':projects,'project_dependencies.json':requirements})
        book = load_database(self.db)
        self.assertEqual(book['Projects'].cell(2,3).value, projects['records'][0][projects['columns'][2]])
        self.assertEqual(json.loads(self.db.with_name('projects.json').read_text())['records'][0]['App version'],'7.7.7')
        self.assertEqual(json.loads(self.db.with_name('project_dependencies.json').read_text())['records'][0]['Version'],'test-version')
        self.assertFalse((self.db.parent / '.transaction.json').exists())

    def test_uninstall_cannot_escape_libraries(self):
        for value in ['../important','/private/tmp/important','libraries']:
            with self.assertRaises(ValueError): output_paths(self.root, {'artifacts':[value]})

    def test_creation_action_updates_selected_release_version(self):
        profile = app.read_rows('Projects')[0]['Profile ID']
        payload = json.dumps({'profile':profile,'version':'8.0.1','action':'full','jobs':1}).encode()
        handler = object.__new__(app.Handler)
        handler.headers = {'Content-Length':str(len(payload))}
        handler.rfile = io.BytesIO(payload)
        handler.path = '/api/create-installer'
        handler.send_json = MagicMock()
        state = {'process':None,'lock':threading.RLock()}
        with patch.object(app,'APP_STATE',state), patch.object(app,'external_live_run',return_value=None), patch.object(app,'start_run') as start:
            handler.do_POST()
            self.assertEqual(handler.send_json.call_args.args[0], {'ok':True})
            self.assertEqual(start.call_args.args[0]['profile'],profile)
        saved = next(p for p in app.read_rows('Projects') if p['Profile ID']==profile)
        self.assertEqual(saved['App version'],'8.0.1')

    def test_launch_failure_still_records_failed_activity(self):
        profile=app.read_rows('Projects')[0]['Profile ID']
        state={'process':None,'lock':threading.RLock()}
        with patch.object(app,'APP_STATE',state), patch.object(app,'external_live_run',return_value=None), patch.object(app.subprocess,'Popen',side_effect=FileNotFoundError('missing engine')):
            with self.assertRaises(ValueError): app.start_run({'action':'clone','profile':profile})
        run=app.read_rows('Runs')[-1]
        self.assertEqual(run['Status'],'failed')
        self.assertIn('Could not start',run['Summary'])

    def test_pause_resume_controls_the_native_child(self):
        child=MagicMock();child.pid=12345;child.poll.return_value=None
        with patch.object(engine,'ACTIVE_CHILD',child), patch.object(engine.os,'killpg') as send:
            engine._handle_engine_pause(engine.signal.SIGUSR1,None)
            self.assertTrue(engine.ENGINE_PAUSED)
            send.assert_called_with(12345,engine.signal.SIGSTOP)
            engine._handle_engine_pause(engine.signal.SIGUSR2,None)
            self.assertFalse(engine.ENGINE_PAUSED)
            send.assert_called_with(12345,engine.signal.SIGCONT)

    def test_only_used_libraries_and_their_prerequisites_are_staged(self):
        entries=[{'name':'used','enabled':True,'requires':['prerequisite']},
                 {'name':'prerequisite','enabled':False},
                 {'name':'unrelated','enabled':False}]
        self.assertEqual([e['name'] for e in enabled_closure(entries)],['prerequisite','used'])

    def test_closed_terminal_pipe_does_not_kill_engine(self):
        class ClosedPipe(io.StringIO):
            def write(self, value): raise BrokenPipeError('closed monitor')
        closed = ClosedPipe()
        with patch.object(engine.sys, 'stdout', closed):
            engine.emit('native build output', flush=True)
            self.assertIsNot(engine.sys.stdout, closed)
            engine.sys.stdout.close()

    def test_catalog_versions_export_to_build_paths(self):
        env = version_environment([{'name':'lz4','version':'1.10.0'},{'name':'flann','version':'1.9.2'},{'name':'hdf5-zlib','version':'HDF5 1.14.6 / zlib 1.3.1'}])
        self.assertEqual(env['LZ4_VERSION'],'1.10.0')
        self.assertEqual(env['FLANN_COMMIT'],'')
        self.assertEqual(env['HDF5_VERSION'],'1.14.6')


if __name__ == '__main__': unittest.main()
