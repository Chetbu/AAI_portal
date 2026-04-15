# VPS Operations Guide

Manual setup steps that live outside the repository — run once on the VPS after initial deployment.

---

## Automated Backups

The backup script is at `scripts/backup.sh`. It backs up `shared.env`, `infrastructure/`, and all `projects/` to `/opt/aai/backups/`, keeping the last 7 archives.

**Add the cron job** (as the `aai` user):

```bash
crontab -e
```

Add this line:

```
0 3 * * * /opt/aai/infrastructure/scripts/backup.sh >> /var/log/aai-backup.log 2>&1
```

**Test it manually first:**

```bash
/opt/aai/infrastructure/scripts/backup.sh
ls -lh /opt/aai/backups/
```

---

## Docker Cleanup

Weekly cleanup of dangling images and stopped containers older than 7 days:

```bash
crontab -e
```

Add:

```
0 4 * * 0 docker system prune -af --filter 'until=168h' >> /var/log/aai-docker-cleanup.log 2>&1
```

---

## Log Rotation

Create `/etc/logrotate.d/aai`:

```bash
sudo tee /etc/logrotate.d/aai << 'EOF'
/var/log/aai-*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
```

---

## Status Overview

At any time, run the status script for a quick health check of the platform:

```bash
/opt/aai/infrastructure/scripts/status.sh
```

Outputs: system uptime / load / memory / disk, all `aai-*` containers with status, per-container CPU and memory usage, and the list of containers on the `aai-public` network.
