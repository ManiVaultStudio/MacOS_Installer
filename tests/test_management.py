import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import installer_app as app
from database_io import load_database, atomic_save_workbook

ROOT = Path(__file__).resolve().parents[1]


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / 'installer_database' / 'installer_database.xlsx'
        self.db.parent.mkdir()
        
        for filename in ['projects.json', 'repositories.json', 'dependencies.json', 'installer_assets.json']:
            shutil.copy(ROOT / 'installer_database' / filename, self.db.with_name(filename))
        shutil.copytree(ROOT / 'installer_database/defaults', self.db.parent / 'defaults')
        self.profiles = self.root / 'scripts/project_profiles'
        self.profiles.mkdir(parents=True)
        for key, value in [('ROOT', self.root), ('DB', self.db), ('PROJECT_PROFILES', self.profiles)]:
            patcher = patch.object(app, key, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_fresh_clone_has_empty_history_and_can_record_run(self):
        book = load_database(self.db)
        self.assertEqual(book['Logs'].max_row, 1)
        self.assertIn('DMG path', next(book['Runs'].iter_rows(values_only=True)))
        book['Runs'].append(['run-1', 'project', 'check', '', '', 'success', '', 'done'])
        atomic_save_workbook(book, self.db)
        self.assertEqual(load_database(self.db)['Runs'].max_row, 2)
        self.assertFalse(self.db.with_name('configuration.json').exists())
        self.assertTrue((self.db.parent / 'local/runs.json').exists())
        self.assertTrue((self.db.parent / 'local/logs.json').exists())

    def test_independent_writes_and_conflict_detection(self):
        first, second = load_database(self.db), load_database(self.db)
        first['Projects'].cell(2, 2).value = 'Changed'
        atomic_save_workbook(first, self.db)
        second['Logs'].append(['now', 'run-1', 'project', 'INFO', 'test', 'message'])
        atomic_save_workbook(second, self.db)
        self.assertEqual(load_database(self.db)['Projects'].cell(2, 2).value, 'Changed')
        second['Projects'].cell(2, 2).value = 'Stale edit'
        # The second object saved history only: it must not adopt a stale config snapshot.
        with self.assertRaises(ValueError):
            atomic_save_workbook(second, self.db)

    def test_plugin_add_and_remove(self):
        profile = app.read_rows('Projects')[0]['Profile ID']
        values = {'Profile ID': profile, 'Repository': 'TestPlugin', 'Ref': 'main', 'Group': 'plugin'}
        app.add_entry({'kind': 'repository', 'values': values})
        row = next(r for r in app.read_rows('Repositories') if r['Repository'] == 'TestPlugin')
        app.remove_entry({'kind': 'repository', 'values': row})
        self.assertFalse(any(r['Repository'] == 'TestPlugin' for r in app.read_rows('Repositories')))

    def test_library_recipe_roundtrip_and_disabled_state(self):
        row = app.read_rows('Dependencies')[0]
        original = {k: row.get(k) for k in ['Artifacts JSON', 'Runtime Files JSON', 'Requires JSON', 'Recipe JSON']}
        values = {**row, 'Enabled': 'false'}
        app.update_build_dependency(values)
        saved = next(r for r in app.read_rows('Dependencies') if r['Name'] == row['Name'])
        self.assertFalse(saved['Enabled'])
        for key in original:
            self.assertEqual(json.loads(saved[key] or ('{}' if key == 'Recipe JSON' else '[]')), json.loads(original[key] or ('{}' if key == 'Recipe JSON' else '[]')))

    def test_library_remove_respects_prerequisites(self):
        row = app.read_rows('Dependencies')[0]
        book = load_database(self.db)
        headers = next(book['Dependencies'].iter_rows(values_only=True))
        values = {"Name": "test-dependent", "Version / commit": "1.0", "Enabled": False,
                  "Requires JSON": json.dumps([row['Name']])}
        book['Dependencies'].append([values.get(h, '') for h in headers])
        atomic_save_workbook(book, self.db)
        with self.assertRaises(ValueError):
            app.remove_entry({'kind': 'dependency', 'values': {'Name': row['Name']}})
        app.remove_entry({'kind': 'dependency', 'values': {'Name': 'test-dependent'}})
        self.assertFalse(any(r['Name'] == 'test-dependent' for r in app.read_rows('Dependencies')))

    def test_project_add_and_remove(self):
        template = app.read_rows('Projects')[0]
        assets = next(r for r in app.read_rows('InstallerAssets') if r['Profile ID'] == template['Profile ID'])
        folder = self.root / assets['Installer materials root']
        folder.mkdir(parents=True)
        (folder / 'app.json').write_text('{}')
        app.add_entry({'kind': 'project', 'values': {'Profile ID': 'test-project', 'Display name': 'Test', 'App version': '1.0.0', 'Template profile': template['Profile ID']}})
        self.assertTrue((self.profiles / 'test-project.env').is_file())
        self.assertTrue((self.root / 'installer_materials/projects/test-project/app.json').is_file())
        app.remove_entry({'kind': 'project', 'values': {'Profile ID': 'test-project'}})
        self.assertFalse((self.profiles / 'test-project.env').exists())
        self.assertFalse(any(r['Profile ID'] == 'test-project' for r in app.read_rows('Repositories')))


if __name__ == '__main__':
    unittest.main()
