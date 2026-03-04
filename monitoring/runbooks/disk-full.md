# Runbook: Disk Full

**Alerts:** `DiskHighUsage` (>80%), `DiskCriticalUsage` (>95%)

## Symptoms

- Write errors: `MISCONF errors writing to disk`
- AOF/checkpoint writes failing in logs
- `ferrite_disk_usage_bytes` exceeding threshold

## Investigation

```bash
# 1. Check disk usage
df -h /data/
du -sh /data/*

# 2. Break down Ferrite data directory
du -sh /data/ferrite/appendonly.aof*
du -sh /data/ferrite/checkpoint-*
du -sh /data/ferrite/tier2/    # tiered storage data

# 3. Check AOF rewrite status
ferrite-cli INFO persistence
# Look at: aof_current_size, aof_base_size, aof_rewrite_in_progress

# 4. List checkpoints by age and size
ls -lhtr /data/ferrite/checkpoint-*/

# 5. Check for temp files (failed rewrites leave debris)
find /data/ferrite/ -name "temp-*" -o -name "*.tmp" | xargs ls -lh

# 6. Monitor growth rate
# In Prometheus: rate(ferrite_disk_usage_bytes[1h])
```

## Remediation

**Immediate (>95% — prevent data loss):**

1. **Clean temp files** from failed operations:
   ```bash
   find /data/ferrite/ -name "temp-*" -mmin +60 -delete
   ```
2. **Remove old checkpoints** (keep latest 2):
   ```bash
   ls -dt /data/ferrite/checkpoint-*/ | tail -n +3 | xargs rm -rf
   ```

**Short-term:**

3. **Compact the AOF:**
   ```bash
   ferrite-cli BGREWRITEAOF
   # Wait for completion, then verify size reduction
   ferrite-cli INFO persistence | grep aof_current_size
   ```
4. **Enable cloud tiering** to offload cold data:
   ```bash
   ferrite-cli CONFIG SET tiered-storage-cloud-enabled yes
   ferrite-cli CONFIG SET tiered-storage-cloud-bucket s3://<bucket>/tier3
   ```
5. **Expand disk** (cloud environments):
   ```bash
   # AWS EBS
   aws ec2 modify-volume --volume-id <vol-id> --size <new_gb>
   # Then resize filesystem
   resize2fs /dev/nvme1n1

   # Kubernetes PVC
   kubectl edit pvc ferrite-data-pvc
   ```

**If writes are blocked:**

6. Temporarily disable AOF to unblock:
   ```bash
   ferrite-cli CONFIG SET appendonly no
   # Free space, then re-enable:
   ferrite-cli CONFIG SET appendonly yes
   ```

## Prevention

- Size data disks to **3x expected dataset size** (AOF + checkpoints + headroom)
- Set `auto-aof-rewrite-percentage 100` to trigger compaction at 2x base size
- Configure checkpoint retention: keep max 3, auto-delete older
- Monitor `ferrite_disk_usage_bytes` with alerts at 70% and 85%
- Track `rate(ferrite_disk_usage_bytes[1d])` to forecast when disk fills
- Enable cloud tiering for datasets that grow unpredictably
