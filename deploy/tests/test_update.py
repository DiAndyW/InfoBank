from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from test_release import DownloadTests as _DownloadTests


class UpdaterTests(_DownloadTests):
    def setUp(self):
        super().setUp()
        self.config.state_dir = self.path / 'state'
        self.config.binary = self.path / 'installed'
        self.config.binary.write_bytes(b'previous executable')
        self.config.maintenance_lock = self.path / 'maintenance.lock'
        self.config.backup_marker = self.path / 'backup.json'
        self.now = datetime.now(timezone.utc)
        self.write_backup(self.now)
        restic = self.path / 'restic'
        restic.write_text('#!/bin/sh\nprintf \'[{"id":"' + 'c'*64 + '","hostname":"notebank"}]\'\n')
        restic.chmod(0o755)
        self.config.restic = str(restic)
        service = self.path / 'systemctl'
        service.write_text('#!/bin/sh\nexit 0\n')
        service.chmod(0o755)
        self.config.systemctl = str(service)
        self.routes['/repos/DiAndyW/InfoBank/releases?per_page=100&page=1'] = json.dumps([self.release]).encode()
        self.routes['/repos/DiAndyW/InfoBank/releases?per_page=100&page=2'] = b'[]'

    def write_backup(self, when):
        self.config.backup_marker.write_text(json.dumps(dict(format_version=1, snapshot_id='c'*64,
            completed_at=when.isoformat().replace('+00:00', 'Z'))))

    def initialize(self):
        self.updater.initialize(self.config, '1.0.0', 'b'*40)

    def test_backup_freshness_boundaries(self):
        for hours, valid in [(23.99, True), (24, True), (24.01, False), (-1, False)]:
            self.write_backup(self.now - timedelta(hours=hours))
            if valid:
                self.updater.validate_backup(self.config, self.now)
            else:
                with self.assertRaises(self.updater.PreflightError):
                    self.updater.validate_backup(self.config, self.now)

    def test_install_and_noop(self):
        self.initialize()
        with patch.object(self.updater, 'wait_ready', return_value=None):
            result = self.updater.run_update(self.config)
        self.assertEqual(result.status, 'installed')
        self.assertEqual(self.config.binary.read_bytes(), self.binary)
        self.assertEqual(self.updater.run_update(self.config).status, 'idle')
        self.assertEqual(json.loads((self.config.state_dir / 'installed.json').read_text())['version'], '1.10.0')

    def test_failure_rolls_back_and_stays_blocked_until_retry(self):
        self.initialize()
        with patch.object(self.updater, 'wait_ready', side_effect=[self.updater.PreflightError('unhealthy'), None]):
            result = self.updater.run_update(self.config)
        self.assertEqual(result.status, 'install_failed')
        self.assertEqual(self.config.binary.read_bytes(), b'previous executable')
        self.assertEqual(self.updater.run_update(self.config).status, 'blocked')
        with patch.object(self.updater, 'wait_ready', return_value=None):
            self.assertEqual(self.updater.run_update(self.config, retry_version='1.10.0').status, 'installed')

    def test_refuses_stale_backup_and_missing_baseline(self):
        self.assertEqual(self.updater.run_update(self.config).status, 'preflight_failed')
        self.initialize()
        self.write_backup(self.now - timedelta(hours=25))
        self.assertEqual(self.updater.run_update(self.config).status, 'preflight_failed')
        self.assertEqual(self.config.binary.read_bytes(), b'previous executable')
        self.write_backup(datetime.now(timezone.utc))
        with patch.object(self.updater, 'wait_ready', return_value=None):
            self.assertEqual(self.updater.run_update(self.config).status, 'installed')

    def test_recovery_restores_previous_binary(self):
        self.initialize()
        self.updater.atomic_json(self.config.state_dir / 'pending.json', dict(
            previous=json.loads((self.config.state_dir / 'installed.json').read_text()),
            candidate=dict(version='1.10.0', sha256=__import__('hashlib').sha256(b'interrupted new executable').hexdigest())))
        (self.config.state_dir / 'previous').write_bytes(b'previous executable')
        self.config.binary.write_bytes(b'interrupted new executable')
        with patch.object(self.updater, 'wait_ready', return_value=None):
            self.updater.recover_pending(self.config)
        self.assertEqual(self.config.binary.read_bytes(), b'previous executable')
        self.assertTrue((self.config.state_dir / 'failed.json').exists())
        self.assertFalse((self.config.state_dir / 'pending.json').exists())

    def test_failed_rollback_retains_recovery_state(self):
        self.initialize()
        with patch.object(self.updater, 'wait_ready', side_effect=self.updater.PreflightError('unhealthy')):
            self.assertEqual(self.updater.run_update(self.config).status, 'rollback_failed')
        self.assertTrue((self.config.state_dir / 'pending.json').exists())

    def test_concurrent_update_does_not_install(self):
        import fcntl
        self.initialize()
        with (self.config.state_dir / 'update.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.updater.run_update(self.config).status, 'busy')
        self.assertEqual(self.config.binary.read_bytes(), b'previous executable')

    def test_monitoring_failure_persists_until_recovery(self):
        self.initialize()
        self.updater.record_result(self.config, self.updater.UpdateResult('install_failed', '1.10.0', 'rolled back'))
        self.updater.record_result(self.config, self.updater.UpdateResult('idle'))
        failure = self.updater.read_state(self.config, 'alert')
        self.assertEqual(failure['status'], 'install_failed')
        self.updater.record_result(self.config, self.updater.UpdateResult('preflight_failed'))
        self.assertEqual(self.updater.read_state(self.config, 'alert')['status'], 'install_failed')
        self.updater.record_result(self.config, self.updater.UpdateResult('installed', '1.11.0'))
        self.assertIsNone(self.updater.read_state(self.config, 'alert'))

    def test_preflight_alert_clears_when_check_recovers(self):
        self.initialize()
        self.updater.record_result(self.config, self.updater.UpdateResult('preflight_failed'))
        self.updater.record_result(self.config, self.updater.UpdateResult('idle'))
        self.assertIsNone(self.updater.read_state(self.config, 'alert'))

    def test_monitoring_network_failure_does_not_change_binary(self):
        self.initialize()
        self.config.healthcheck_url = 'https://hc-ping.com/test-secret'
        with patch('urllib.request.build_opener', side_effect=OSError('test-secret')):
            self.updater.record_result(self.config, self.updater.UpdateResult('installed', '1.10.0'))
        self.assertEqual(self.config.binary.read_bytes(), b'previous executable')

    def test_missing_or_wrong_backup_snapshot_refuses_install(self):
        self.initialize()
        for content in ['[]', '[{"id":"wrong","hostname":"notebank"}]', '[{"id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","hostname":"other"}]']:
            Path(self.config.restic).write_text("#!/bin/sh\nprintf '%s' '" + content + "'\n")
            self.assertEqual(self.updater.run_update(self.config).status, 'preflight_failed')
            self.assertEqual(self.config.binary.read_bytes(), b'previous executable')

    def test_changed_assets_cannot_bypass_quarantine(self):
        self.initialize()
        self.routes['/binary'] = b'altered'
        self.assertEqual(self.updater.run_update(self.config).status, 'blocked')
        self.routes['/binary'] = self.binary
        self.assertEqual(self.updater.run_update(self.config).status, 'blocked')

    def test_maintenance_lock_preserves_binary(self):
        import fcntl
        self.initialize()
        with self.config.maintenance_lock.open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.updater.run_update(self.config).status, 'preflight_failed')
        self.assertEqual(self.config.binary.read_bytes(), b'previous executable')

    def test_invalid_previous_binary_prevents_ambiguous_recovery(self):
        self.initialize()
        self.updater.atomic_json(self.config.state_dir / 'pending.json', dict(
            previous=json.loads((self.config.state_dir / 'installed.json').read_text()),
            candidate=dict(version='1.10.0')))
        (self.config.state_dir / 'previous').write_bytes(b'corrupt')
        self.assertEqual(self.updater.run_update(self.config).status, 'rollback_failed')
        self.assertTrue((self.config.state_dir / 'pending.json').exists())

    def test_recovery_refuses_unknown_current_binary(self):
        self.initialize()
        self.updater.atomic_json(self.config.state_dir / 'pending.json', dict(
            previous=json.loads((self.config.state_dir / 'installed.json').read_text()),
            candidate=dict(version='1.10.0', sha256='a'*64)))
        (self.config.state_dir / 'previous').write_bytes(b'previous executable')
        self.config.binary.write_bytes(b'unknown operator binary')
        with patch.object(self.updater, 'wait_ready', return_value=None):
            self.assertEqual(self.updater.run_update(self.config).status, 'rollback_failed')
        self.assertEqual(self.config.binary.read_bytes(), b'unknown operator binary')
        self.assertTrue((self.config.state_dir / 'pending.json').exists())

    def test_listener_ownership_uses_process_socket(self):
        proc = self.path / 'proc/123'
        (proc / 'fd').mkdir(parents=True)
        (proc / 'net').mkdir()
        (proc / 'net/tcp').write_text('header\n0: 0100007F:1F90 00000000:0000 0A 0 0 0 0 0 42\n')
        (proc / 'fd/4').symlink_to('socket:[42]')
        self.assertTrue(self.updater.listener_owned_by(123, self.path / 'proc'))
        (proc / 'fd/4').unlink()
        (proc / 'fd/4').symlink_to('socket:[99]')
        self.assertFalse(self.updater.listener_owned_by(123, self.path / 'proc'))

    def test_readiness_requires_stable_process_and_owned_listener(self):
        from contextlib import nullcontext
        from types import SimpleNamespace
        observations = []
        def service(args, **kwargs):
            observations.append(args)
            return b'123' if 'show' in args else b''
        with patch.object(self.updater, 'command', side_effect=service), \
             patch('os.path.samefile', return_value=True), \
             patch.object(self.updater, 'listener_owned_by', return_value=True), \
             patch('urllib.request.urlopen', side_effect=lambda *a, **kw: nullcontext(SimpleNamespace(status=200))), \
             patch('time.sleep'):
            self.updater.wait_ready(self.config)
        self.assertGreaterEqual(sum('show' in args for args in observations), 3)

    def test_alert_survives_actual_idle_poll_after_failed_install(self):
        self.initialize()
        with patch.object(self.updater, 'wait_ready', side_effect=[self.updater.PreflightError('unhealthy'), None]):
            self.assertEqual(self.updater.run_update(self.config).status, 'install_failed')
        self.routes['/repos/DiAndyW/InfoBank/releases?per_page=100&page=1'] = b'[]'
        self.assertEqual(self.updater.run_update(self.config).status, 'idle')
        self.assertEqual(self.updater.read_state(self.config, 'alert')['status'], 'install_failed')

    def test_recovers_at_each_atomic_install_boundary(self):
        self.initialize()
        previous = self.updater.read_state(self.config, 'installed')
        candidate = dict(version='1.10.0', sha256=__import__('hashlib').sha256(self.binary).hexdigest())
        for phase in ['before_replace', 'after_replace', 'after_installed_state']:
            with self.subTest(phase=phase):
                (self.config.state_dir / 'previous').write_bytes(b'previous executable')
                self.updater.atomic_json(self.config.state_dir / 'pending.json', dict(previous=previous, candidate=candidate))
                self.config.binary.write_bytes(b'previous executable' if phase == 'before_replace' else self.binary)
                if phase == 'after_installed_state':
                    self.updater.atomic_json(self.config.state_dir / 'installed.json', candidate)
                with patch.object(self.updater, 'wait_ready', return_value=None):
                    self.updater.recover_pending(self.config)
                self.assertEqual(self.config.binary.read_bytes(), b'previous executable')
                self.assertEqual(self.updater.read_state(self.config, 'installed'), previous)
                self.assertIsNone(self.updater.read_state(self.config, 'pending'))


del _DownloadTests
