# Runbook: Backup Failure

**Alerts:** `BackupOverdue` (no successful backup in >24h)

## Symptoms

- No recent backup files in backup destination
- `ferrite_last_backup_timestamp` is stale
- Backup CronJob pods in `Error` or `CrashLoopBackOff` state

## Investigation

```bash
# 1. Check last successful backup time
ferrite-cli INFO persistence
# Look at: last_checkpoint_time, last_checkpoint_status

# 2. Check backup job logs
# Kubernetes
kubectl logs -l job-name=ferrite-backup --tail=100
kubectl get jobs -l app=ferrite-backup --sort-by=.status.startTime

# Systemd
journalctl -u ferrite-backup.service --since "24 hours ago"

# 3. Check disk space on backup destination
df -h /backups/
du -sh /backups/*

# 4. Check S3/cloud connectivity (if using cloud backups)
aws s3 ls s3://<backup-bucket>/ferrite/ --region <region>
# Check IAM role / credentials expiry

# 5. Check if a backup is currently in progress
ferrite-cli INFO persistence
# Look at: checkpoint_in_progress
# A stuck backup may block new ones
```

## Remediation

**Trigger manual backup:**

1. ```bash
   ferrite-cli BGSAVE
   # or for checkpoint-based backup:
   ferrite-cli CHECKPOINT /backups/manual-$(date +%Y%m%d-%H%M%S)
   ```

**If disk is full:**

2. Remove old backups:
   ```bash
   ls -lt /backups/ | tail -n +6 | xargs rm -rf  # keep last 5
   ```
3. Expand disk volume (cloud):
   ```bash
   # Resize PVC in Kubernetes
   kubectl edit pvc ferrite-backup-pvc  # increase spec.resources.requests.storage
   ```

**If S3 connectivity failed:**

4. Verify credentials:
   ```bash
   aws sts get-caller-identity
   ```
5. Check bucket policy and network (VPC endpoints, security groups)
6. Retry:
   ```bash
   ferrite-cli CHECKPOINT-UPLOAD s3://<bucket>/ferrite/$(date +%Y%m%d)
   ```

**If backup process is stuck:**

7. Check for zombie process:
   ```bash
   ps aux | grep ferrite | grep -i save
   ```
8. If stuck >2x normal duration, restart the backup (not the server):
   ```bash
   ferrite-cli CHECKPOINT ABORT
   ferrite-cli BGSAVE
   ```

## Prevention

- Retain at least 3 days of backups with automated rotation
- Monitor `ferrite_last_backup_timestamp` with alert at 20h (before 24h SLA)
- Test restore from backup monthly
- Ensure backup disk is 3x the dataset size
- Use separate credentials for backup with minimal permissions
