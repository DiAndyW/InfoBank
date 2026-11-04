import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackupTests(unittest.TestCase):
    def test_marker_only_changes_after_complete_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['setpriv', 'restic', 'curl', 'flock']:
                script = root / name
                script.write_text('#!/bin/bash\n' + (
                    'echo dump\n' if name == 'setpriv' else
                    'if [[ "$1" == "$FAIL_STEP" ]]; then exit 1; fi\nif [[ "$1" == backup ]]; then echo \'{"message_type":"summary","snapshot_id":"' + 'a'*64 + '"}\'; fi\n' if name == 'restic' else 'exit 0\n'))
                script.chmod(0o755)
            source = (ROOT / 'notebank-backup').read_text().replace('/run/lock/notebank-maintenance.lock', str(root / 'lock'))
            (root / 'backup').write_text(source)
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], STATE_DIRECTORY=str(root), HEALTHCHECK_URL='https://example.invalid/check')
            subprocess.run(['bash', str(root / 'backup')], env=env, check=True, capture_output=True)
            marker = root / 'success.json'
            self.assertEqual(json.loads(marker.read_text())['snapshot_id'], 'a'*64)
            previous = marker.read_bytes()
            for step in ['backup', 'forget', 'check']:
                result = subprocess.run(['bash', str(root / 'backup')], env=dict(env, FAIL_STEP=step), capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(marker.read_bytes(), previous)

            import fcntl
            import sys
            (root / 'flock').write_text('#!' + sys.executable + '\nimport fcntl\nfcntl.flock(9, fcntl.LOCK_EX)\n')
            with (root / 'lock').open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                child = subprocess.Popen(['bash', str(root / 'backup')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        child.wait(timeout=0.2)
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    stdout, stderr = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, stderr.decode())
