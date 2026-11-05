# Server updates

CI runs Go tests with PostgreSQL 16, desktop tests/builds on both Windows and macOS, and Kit tests plus an unsigned iPhone simulator build. Creating a `server-vMAJOR.MINOR.PATCH` tag authorizes automatic Server installation after all checks pass and a complete signed release is published. App delivery remains separate.

Automatic releases must preserve database and API compatibility with the previous Server and installed apps. Review migration reversibility by the old executable and old-client sync behaviour before tagging. A binary rollback does not undo migrations. Breaking changes require a separately coordinated rollout; a successful health check cannot prove compatibility.

## GitHub setup

These are administrator setup steps, not actions performed by adding these files:

1. Keep the private repository on GitHub Pro. Protect `main` with a ruleset requiring pull requests and the CI `checks` aggregate status. Run CI once to select the exact check context shown by GitHub. Require the branch to be up to date, block force pushes/deletion and disable routine administrator bypass. Do not require a second person's approval for this single-maintainer repository.
2. Protect tags matching `server-v*` against updates and deletion, including routine bypass. Only the maintainer should authorize creation. Never reuse a version or replace published release assets. The release workflow independently runs all checks on the tagged commit and verifies main ancestry.
3. On a trusted administrator machine, install Minisign and generate a dedicated CI signing key with `minisign -G -W -p release.pub -s release.key`. `-W` deliberately creates an unencrypted key for unattended signing. Keep a recovery copy in the password manager; add the complete private-key file as repository Actions secret `SERVER_RELEASE_MINISIGN_KEY` through GitHub's secret UI. Never commit it or print it to a terminal/log. Delete temporary plaintext copies after secure storage. Install only its public key on the VM.
4. Keep signing-secret references restricted to the gated publish job. Protect workflow changes during review. A compromised workflow with access to this secret can sign arbitrary binaries; Minisign cannot detect that.
5. Create a fine-grained GitHub token restricted to this repository with Contents: read. Store it in the password manager and VM file below, not in CI. Plan for token expiry/rotation; failed authentication leaves the existing Server running and alerts.
6. Create a separate healthchecks.io check for the updater with the existing email destination. Suggested period: 5 minutes, grace: 25 minutes, covering the service's 20-minute maximum runtime. The backup check remains independent. Enable failure alerts and verify the alert destination during authorized setup.

CI pins Actions by commit. Review and update these pins and the Xcode image path periodically. Windows/macOS hosted results are required; local validation alone does not establish that they pass.

## One-time VM setup

Run only after reviewing the implementation and authorizing production setup. Current VM is documented as Ubuntu 24.04 arm64; confirm `uname -m` reports `aarch64` before proceeding. Existing Server and Caddy configuration stay manually managed.

Install Ubuntu packages `python3`, `minisign`, `restic`, `curl` and `util-linux` (flock). Existing backup setup supplies PostgreSQL/R2 credentials. Python 3.11 or later is required.

As root, install reviewed files from the repository:

```sh
install -m 755 deploy/notebank-update deploy/release-manifest.py deploy/notebank-backup /usr/local/sbin/
install -m 644 deploy/notebank-update.service deploy/notebank-update.timer deploy/notebank-backup.service /etc/systemd/system/
install -d -m 700 /var/lib/notebank-update
systemctl daemon-reload
```

Using a private editor or secret-management transfer, create these root-owned files (mode 600, containing no shell commands except the documented environment assignment):

- `/etc/notebank/release.pub`: trusted Minisign public-key file, copied independently of downloaded releases.
- `/etc/notebank/github-read-token`: read-only GitHub token as a single line.
- `/etc/notebank/update.env`: `UPDATE_HEALTHCHECK_URL=https://hc-ping.com/<new-check-id>`.

Existing `/etc/notebank/backup.env` remains root-only. Updater service loads its restic credentials to confirm the recorded snapshot still exists. The production NoteBank shared secret never enters the updater or CI.

The revised backup job and updater share `/run/lock/notebank-maintenance.lock`. Backups hold it for the whole dump/backup/retention/check operation; updater holds it for snapshot validation through install/rollback. The updater refuses overlapping maintenance and retries preflight later. Do not replace that lock file while either process runs.

Run the updated backup job once and confirm success before enabling updates:

```sh
systemctl start notebank-backup.service
systemctl status notebank-backup.service
```

Successful completion creates `/var/lib/notebank-backup/success.json` containing UTC completion time and the exact snapshot ID. Failed backup/check leaves the prior marker. Updater requires that snapshot in the configured repository with host `notebank`, completed within 24 hours. An old installation without this marker needs a new successful backup. Since the nightly timer has a randomized delay, a brief freshness refusal near the 24-hour boundary is expected; do not weaken the gate.

Initialize the baseline using the version and exact source commit actually used for the currently installed binary:

```sh
/usr/local/sbin/notebank-update initialize --version VERIFIED_VERSION --commit VERIFIED_COMMIT
```

Load the read token first as described above; initialization reads it but makes no release request. Do not infer production source from the Mac's current branch. If the installed binary's origin is unknown, establish a reviewed manual baseline first. Initialization records the current executable checksum and refuses to overwrite existing state.

After validating the baseline, backup marker, credentials, key and monitoring:

```sh
systemctl enable --now notebank-update.timer
systemctl list-timers notebank-update.timer
```

A controlled release and rollback demonstration is required before considering rollout verified. The operator must explicitly authorize that production exercise.

## Publishing

After merging compatible changes to main and confirming CI, create and push a new `server-v1.2.3` tag using the next unused version. These Git operations belong to the user, not the agent. Tagging is deployment authorization.

The tag workflow reruns all mandatory checks, builds a static Linux arm64 binary once, signs `manifest.json`, uploads all three assets to a draft, and publishes only when complete. A duplicate tag/release is an error. Drafts, prereleases and app release tags are ignored by the VM. The VM chooses semantic version order rather than GitHub's latest-release designation and never downgrades automatically.

Published assets:

- `notebank-server-linux-arm64`
- `manifest.json` (version, source commit, target, filename and SHA-256)
- `manifest.json.minisig`

## Checking now and retrying

Trigger the configured updater immediately using the same service as the timer:

```sh
sudo systemctl start notebank-update.service
sudo journalctl -u notebank-update.service -n 30 --no-pager
```

Installation failures and invalid releases are quarantined by version. A changed asset cannot bypass quarantine. Ordinary checks may install a newer version. Preflight network/credential errors and stale backups can retry on the next poll without replacing the running executable.

For an explicit retry, first fix the cause, confirm compatibility, then run the same updater with its environment as root (replace the example version):

```sh
sudo bash -c 'set -a; . /etc/notebank/backup.env; . /etc/notebank/update.env; exec /usr/local/sbin/notebank-update retry "$1"' bash 1.2.3
```

Retry names the latest eligible version and repeats every verification and backup gate. Never enable shell tracing while loading secrets. The update lock covers manual and scheduled runs, including persistent monitoring state.

Updater output contains sanitized operational status only. A failed deployment alert persists through idle polls and transient preflight errors until an explicit successful retry or newer successful deployment. Monitoring delivery failure does not roll back a healthy deployment; missed heartbeats still alert independently.

## Recovery

The old executable is retained at `/var/lib/notebank-update/previous`. Readiness requires the same active executable and ownership of its loopback TCP listener over three consecutive observations, one second apart. Before replacement, the updater fsyncs a pending record with old/new identities. Next invocation reconciles interrupted installation by restoring and checking the verified previous executable, quarantining the interrupted candidate. If restoration is ambiguous or unhealthy, it stops with pending state preserved and alerts. No automatic database restore occurs.

If both new and previous binaries fail:

1. Stop the updater timer, inspect the Server unit and logs, and preserve `/var/lib/notebank-update/` before changes.
2. Diagnose migration/configuration problems; do not clear pending state or overwrite the baseline just to silence the alert.
3. Restore a trusted compatible binary manually, or follow RESTORE.md for deliberate database recovery. Database restore can discard newer data and requires separate authorization.
4. Reconcile recorded binary identity and pending transaction only after the service is healthy; make a recovery copy before editing root-owned state. Explicitly retry a corrected release or publish a newer version. Re-enable the timer and verify monitoring.

During signing-key rotation, install the new public key manually using a trusted channel before publishing with the new private key. Never trust a replacement key supplied by an unverified release.
