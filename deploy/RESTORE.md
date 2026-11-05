# Backups and restore

Every night around 04:00 UTC, `notebank-backup.timer` dumps the database and backs it up with `/var/lib/notebank/attachments` to the `notebank-backups` bucket on Cloudflare R2. restic encrypts everything before upload. It keeps 7 daily, 4 weekly and 12 monthly snapshots. healthchecks.io emails you if a run fails or doesn't happen.

Secrets live in `/etc/notebank/` (root, `600`) and in the password manager:

- `notebank.env`: `NOTEBANK_SECRET`
- `backup.env`: `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `HEALTHCHECK_URL`

Without `RESTIC_PASSWORD` the backups can't be read by anyone.

## Get a snapshot

Everything below runs as root (`sudo -i`).

```
set -a; . /etc/notebank/backup.env; set +a
restic snapshots
restic restore latest --target /root/restore      # or a snapshot ID instead of latest
```

This gives `/root/restore/var/lib/notebank-backup/notebank.dump` and `/root/restore/var/lib/notebank/attachments/`.

## Put it back

```
systemctl stop notebank
runuser -u postgres -- dropdb --if-exists notebank
runuser -u postgres -- createdb -O notebank notebank
setpriv --reuid=notebank --regid=notebank --clear-groups \
  pg_restore --no-owner -d notebank -h /var/run/postgresql < /root/restore/var/lib/notebank-backup/notebank.dump
rsync -a --delete /root/restore/var/lib/notebank/attachments/ /var/lib/notebank/attachments/
chown -R notebank:notebank /var/lib/notebank/attachments
systemctl start notebank
rm -r /root/restore
```

`pg_restore` runs as `notebank`, which can't read `/root`, so root's shell feeds it the dump on stdin.

## Check a backup without touching live data

```
set -a; . /etc/notebank/backup.env; set +a
restic restore latest --target /root/restore-test
runuser -u postgres -- createdb -O notebank notebank_restore_test
setpriv --reuid=notebank --regid=notebank --clear-groups \
  pg_restore --no-owner -d notebank_restore_test -h /var/run/postgresql < /root/restore-test/var/lib/notebank-backup/notebank.dump
for db in notebank notebank_restore_test; do
  runuser -u postgres -- psql -d $db -Atc "select (select count(*) from items), (select count(*) from attachments)"
done
diff -r /var/lib/notebank/attachments /root/restore-test/var/lib/notebank/attachments && echo attachments match
runuser -u postgres -- dropdb notebank_restore_test
rm -r /root/restore-test
```

Both count lines should match, apart from anything added since the snapshot.

## Rebuild on a new VM

1. Ubuntu 24.04. Open TCP 22, 80 and 443 in the cloud firewall. On Oracle, also insert iptables ACCEPT rules for 80 and 443 above the REJECT and run `netfilter-persistent save`. Point the `notes` A record at the new IP (no proxy).
2. If the R2 token is limited to the old VM's IP, update it in Cloudflare.
3. Install Go (go.dev tarball), `postgresql`, `restic`, and Caddy from its official apt repo.
4. Clone the repo, then `cd server && CGO_ENABLED=0 /usr/local/go/bin/go build -o /usr/local/bin/notebank-server ./cmd/notebank-server`.
5. Set up the user, directories and database:
   ```
   useradd --system --shell /usr/sbin/nologin notebank
   install -d -o notebank -g notebank -m 700 /var/lib/notebank /var/lib/notebank/attachments
   runuser -u postgres -- createuser notebank
   ```
6. Recreate both env files from the password manager (`install -D -m 600 /dev/null <file>`, then edit). Reusing the same `NOTEBANK_SECRET` keeps the apps working.
7. Install the files in this folder:
   ```
   install -m 644 deploy/notebank.service deploy/notebank-backup.service deploy/notebank-backup.timer /etc/systemd/system/
   install -m 755 deploy/notebank-backup /usr/local/sbin/
   install -m 644 deploy/Caddyfile /etc/caddy/Caddyfile
   systemctl daemon-reload
   ```
8. Follow **Get a snapshot** and **Put it back**. `dropdb` has nothing to drop, and `systemctl start notebank` is the first start.
9. `systemctl enable notebank notebank-backup.timer`, then `systemctl restart caddy`.

## Automatic release updater

See [UPDATES.md](UPDATES.md) for CI, signing keys, installation and recovery. On a replacement VM, recover the trusted public key and read-only repository credential from the password manager, reinstall the updater units manually, establish the actual installed binary baseline and run a fresh successful backup before enabling the timer. Preserve transaction state when recovering an existing VM; do not initialize over an interrupted update. Caddy and the Server unit remain manual.
