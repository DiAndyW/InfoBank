import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'deploy/desktop-release.py'
FILES = ['desktop/src-tauri/tauri.conf.json', 'desktop/src-tauri/Cargo.toml',
         'desktop/package.json']


class DesktopReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('[package]\nversion = "0.2.0"\n' if name.endswith('.toml')
                            else '{"version":"0.2.0"}')
        self.mac_sig = self.root / 'mac.sig'
        self.windows_sig = self.root / 'windows.sig'
        self.mac_sig.write_text('mac signature\n')
        self.windows_sig.write_text('windows signature\n')

    def check(self, tag):
        return subprocess.run([sys.executable, str(SCRIPT), 'check-version', tag,
                               '--root', str(self.root)], capture_output=True, text=True,
                              cwd=self.root)

    def manifest(self, **changes):
        args = dict(version='0.2.0', mac_asset='NoteBank.app.tar.gz', mac_sig=self.mac_sig,
                    windows_asset='NoteBank_0.2.0_x64-setup.exe', windows_sig=self.windows_sig)
        args.update(changes)
        command = [sys.executable, str(SCRIPT), 'manifest']
        for name, value in args.items():
            command.extend(['--' + name.replace('_', '-'), str(value)])
        return subprocess.run(command, capture_output=True, text=True, cwd=self.root)

    def test_matching_tag_passes(self):
        result = self.check('desktop-v0.2.0')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_mismatched_file_is_named(self):
        for name in FILES:
            with self.subTest(file=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original.replace('0.2.0', '0.1.0'))
                result = self.check('desktop-v0.2.0')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                path.write_text(original)

    def test_rejects_bad_tags(self):
        for tag in ['desktop-v1.2', 'desktop-v01.2.3', 'desktop-v1.2.3-rc.1',
                    'server-v1.2.3', 'desktop-v0.2.0\n', 'desktop-v٠.2.0']:
            with self.subTest(tag=tag):
                result = self.check(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr.strip(), 'invalid desktop release tag')

    def test_manifest_has_both_platforms_and_versioned_urls(self):
        result = self.manifest()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertEqual(manifest['version'], '0.2.0')
        self.assertEqual(manifest['platforms'], {
            'darwin-aarch64': {'signature': 'mac signature\n', 'url':
                'https://github.com/DiAndyW/InfoBank/releases/download/desktop-v0.2.0/NoteBank.app.tar.gz'},
            'windows-x86_64': {'signature': 'windows signature\n', 'url':
                'https://github.com/DiAndyW/InfoBank/releases/download/desktop-v0.2.0/NoteBank_0.2.0_x64-setup.exe'}})
        self.assertTrue(manifest['pub_date'].endswith('Z'))
        published = datetime.fromisoformat(manifest['pub_date'].replace('Z', '+00:00'))
        self.assertLess(abs((datetime.now(timezone.utc) - published).total_seconds()), 30)

    def test_manifest_refuses_empty_signature_or_unsafe_name(self):
        for field in ['mac_sig', 'windows_sig']:
            path = self.root / 'empty.sig'
            for content in ['', ' \n']:
                path.write_text(content)
                with self.subTest(field=field, content=content):
                    self.assertNotEqual(self.manifest(**{field: path}).returncode, 0)
        for field in ['mac_asset', 'windows_asset']:
            for name in ['../asset', 'dir/asset', 'dir\\asset', '', '..']:
                with self.subTest(field=field, name=name):
                    self.assertNotEqual(self.manifest(**{field: name}).returncode, 0)

    def test_manifest_rejects_invalid_versions(self):
        for version in ['1.2', '01.2.3', '1.2.3-rc.1', '1.2.3\n']:
            with self.subTest(version=version):
                self.assertNotEqual(self.manifest(version=version).returncode, 0)

    def test_imported_helper_checks_versions(self):
        spec = importlib.util.spec_from_file_location('desktop_release', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.check_version('desktop-v0.2.0', self.root)


if __name__ == '__main__':
    unittest.main()
