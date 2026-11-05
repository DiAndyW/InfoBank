import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    import sys
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.module = load('release_manifest', ROOT / 'release-manifest.py')
        self.valid = dict(format_version=1, version='1.2.3', commit='a' * 40,
                          os='linux', arch='arm64', filename='notebank-server-linux-arm64', sha256='b' * 64)

    def test_accepts_signed_identity(self):
        self.assertEqual(self.module.parse_manifest(json.dumps(self.valid).encode()), self.valid)

    def test_rejects_ambiguous_or_unsafe_manifest(self):
        for field, value in [('version', '01.2.3'), ('version', '1.2.3-rc1'), ('commit', 'main'),
                             ('arch', 'amd64'), ('filename', '../server'), ('sha256', 'z' * 64),
                             ('format_version', True), ('extra', 'surprise')]:
            with self.subTest(field=field, value=value):
                data = dict(self.valid, **{field: value})
                with self.assertRaises(ValueError):
                    self.module.parse_manifest(json.dumps(data).encode())
        with self.assertRaises(ValueError):
            self.module.parse_manifest(json.dumps(self.valid).replace('"version":', '"version":"9.0.0", "version":').encode())

    def test_numeric_version_order(self):
        self.assertGreater(self.module.version_tuple('1.10.0'), self.module.version_tuple('1.9.9'))


if __name__ == '__main__':
    unittest.main()

class DownloadTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        import subprocess
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        import threading
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        subprocess.run(['minisign', '-G', '-W', '-p', str(self.path / 'key.pub'), '-s', str(self.path / 'key')], check=True, capture_output=True)
        self.binary = b'linux executable fixture'
        (self.path / 'binary').write_bytes(self.binary)
        manifest = load('release_manifest', ROOT / 'release-manifest.py').make_manifest('1.10.0', 'a' * 40, self.path / 'binary')
        (self.path / 'manifest.json').write_bytes(manifest)
        subprocess.run(['minisign', '-S', '-s', str(self.path / 'key'), '-m', str(self.path / 'manifest.json')], check=True, capture_output=True)
        self.routes = {}
        routes = self.routes
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                value = routes.get(self.path)
                if value is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(value)
            def log_message(self, *args):
                pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.origin = f'http://127.0.0.1:{self.server.server_port}'
        self.routes['/manifest'] = manifest
        self.routes['/signature'] = (self.path / 'manifest.json.minisig').read_bytes()
        self.routes['/binary'] = self.binary
        self.release = dict(tag_name='server-v1.10.0', draft=False, prerelease=False, assets=[
            dict(name=name, url=self.origin + '/' + route) for name, route in [
                ('manifest.json', 'manifest'), ('manifest.json.minisig', 'signature'),
                ('notebank-server-linux-arm64', 'binary')]])
        import importlib.machinery
        loader = importlib.machinery.SourceFileLoader('updater', str(ROOT / 'notebank-update'))
        spec = importlib.util.spec_from_loader('updater', loader)
        import sys
        self.updater = importlib.util.module_from_spec(spec)
        sys.modules['updater'] = self.updater
        loader.exec_module(self.updater)
        self.config = self.updater.Config(api_url=self.origin, token='secret-test-token', public_key=self.path / 'key.pub')

    def test_real_signature_and_binary_verified(self):
        result = self.updater.verify_release(self.release, self.config, self.path / 'staging')
        self.assertEqual(result['version'], '1.10.0')
        self.assertEqual((self.path / 'staging/notebank-server-linux-arm64').read_bytes(), self.binary)

    def test_tampered_assets_and_wrong_tag_rejected(self):
        for route in ['/manifest', '/signature', '/binary']:
            with self.subTest(route=route):
                old = self.routes[route]
                self.routes[route] = (old.replace(old.splitlines()[1][:8], b'AAAAAAAA', 1) if route == '/signature' else old + b'tampered')
                with self.assertRaises(self.updater.InvalidRelease):
                    self.updater.verify_release(self.release, self.config, self.path / 'staging')
                self.routes[route] = old
        self.release['tag_name'] = 'server-v2.0.0'
        with self.assertRaises(self.updater.InvalidRelease):
            self.updater.verify_release(self.release, self.config, self.path / 'staging')

    def test_selects_semantic_latest_across_pages(self):
        old = dict(self.release, tag_name='server-v1.9.9')
        unrelated = dict(self.release, tag_name='desktop-v99.0.0')
        preview = dict(self.release, tag_name='server-v99.0.0', prerelease=True)
        self.routes['/repos/DiAndyW/InfoBank/releases?per_page=100&page=1'] = json.dumps([old, unrelated, preview]).encode()
        self.routes['/repos/DiAndyW/InfoBank/releases?per_page=100&page=2'] = json.dumps([self.release]).encode()
        self.routes['/repos/DiAndyW/InfoBank/releases?per_page=100&page=3'] = b'[]'
        result = self.updater.discover_release(self.origin, self.config.token)
        self.assertEqual(result['tag_name'], 'server-v1.10.0')

    def test_off_origin_asset_rejected_without_leaking_token(self):
        self.release['assets'][0]['url'] = 'http://example.invalid/asset'
        with self.assertRaises(self.updater.InvalidRelease) as error:
            self.updater.verify_release(self.release, self.config, self.path / 'staging')
        self.assertNotIn('secret-test-token', str(error.exception))
