# Runbook: High Latency

**Alerts:** `HighLatencyP99` (>10ms), `HighLatencyP999` (>50ms)

## Symptoms

- P99/P999 latency spikes on `ferrite_command_duration_seconds`
- Client-side timeouts or increased error rates
- Degraded throughput visible in Grafana dashboards

## Investigation

```bash
# 1. Check slow log for expensive commands
ferrite-cli SLOWLOG GET 20

# 2. Check latency stats per event type
ferrite-cli LATENCY LATEST
ferrite-cli LATENCY HISTORY <event>

# 3. Check command distribution (look for O(N) commands)
ferrite-cli INFO commandstats
# Watch for high calls to KEYS, SMEMBERS, LRANGE, SORT

# 4. Check io_uring status (Linux only)
ferrite-cli INFO io_uring
# Look at: pending_submissions, completion_backlog

# 5. Check system-level
# CPU saturation
top -p $(pgrep ferrite)
# Disk I/O (relevant if tiered storage is active)
iostat -x 1 5
# Network
ss -s
```

## Remediation

**Immediate:**

1. **Kill long-running commands** if blocking:
   ```bash
   ferrite-cli CLIENT LIST
   ferrite-cli CLIENT KILL ID <id>
   ```
2. **Disable KEYS command** in production:
   ```bash
   ferrite-cli ACL SETUSER default -KEYS
   ```

**Short-term:**

3. Replace O(N) commands:
   - `KEYS *` → `SCAN` with cursor
   - `SMEMBERS` on large sets → `SSCAN`
   - `LRANGE 0 -1` on large lists → paginate
4. **Tune io_uring** if completion backlog is high:
   ```bash
   ferrite-cli CONFIG SET io-uring-entries 4096
   ```
5. If tiered storage reads are slow, increase read-ahead buffer:
   ```bash
   ferrite-cli CONFIG SET tiered-read-ahead-kb 256
   ```

**Long-term:**

6. Review data model — use hashes/sorted sets instead of large strings
7. Enable read replicas to distribute read load

## Prevention

- Set `slowlog-log-slower-than 5000` (5ms) to catch slow queries early
- Benchmark after every schema or workload change
- Avoid O(N) commands on collections with >10K elements
- Monitor `ferrite_command_duration_seconds` histograms by command type
- Load-test with production-like traffic before releases
