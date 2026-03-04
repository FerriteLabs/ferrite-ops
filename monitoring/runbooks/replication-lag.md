# Runbook: Replication Lag

**Alerts:** `ReplicationLag` (>1s), `ReplicationBroken` (link down >30s)

## Symptoms

- Stale reads from replicas
- `ferrite_replication_lag_seconds` increasing
- Replica logs show `LOADING` state or repeated sync attempts

## Investigation

```bash
# 1. Check replication status on primary
ferrite-cli -h <primary> INFO replication
# Key fields: connected_slaves, slave0:offset,lag

# 2. Check replication status on replica
ferrite-cli -h <replica> INFO replication
# Key fields: master_link_status, master_last_io_seconds_ago, master_sync_in_progress

# 3. Calculate offset delta
# primary_repl_offset - replica_repl_offset = bytes behind

# 4. Check replication backlog
ferrite-cli -h <primary> INFO replication
# repl_backlog_size, repl_backlog_first_byte_offset

# 5. Network diagnostics between primary and replica
ping <primary_host>
iperf3 -c <primary_host> -t 5
# Check for packet loss or bandwidth saturation
```

## Remediation

**If link is down (`master_link_status: down`):**

1. Verify network connectivity between primary and replica
2. Check if primary is overloaded (CPU, memory, connections)
3. Restart replication if stuck:
   ```bash
   ferrite-cli -h <replica> REPLICAOF <primary_host> <primary_port>
   ```

**If lag is growing (link up but offset diverging):**

4. Check if replica is doing a full resync (expensive):
   ```bash
   # Look for master_sync_in_progress:1 on replica
   # If yes, wait for it to complete — do not interrupt
   ```
5. Increase backlog to avoid full resyncs:
   ```bash
   ferrite-cli -h <primary> CONFIG SET repl-backlog-size 256mb
   ```
6. Check if replica disk I/O is bottleneck (RDB loading):
   ```bash
   iostat -x 1 5  # on replica host
   ```

**If backlog overflowed (forced full resync):**

7. Allow full resync to complete, then increase backlog:
   ```bash
   ferrite-cli -h <primary> CONFIG SET repl-backlog-size 512mb
   ```
8. Consider `diskless-sync yes` on primary if network is faster than disk

## Prevention

- Size `repl-backlog-size` to hold 60s of write throughput
- Monitor `ferrite_replication_lag_seconds` with alert at 500ms
- Ensure replicas have equivalent or better disk I/O than primary
- Place primary and replicas in the same availability zone
- Test failover quarterly to verify replication health
