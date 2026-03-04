# Runbook: High Memory Usage

**Alerts:** `HighMemoryUsage` (>80%), `CriticalMemoryUsage` (>95%)

## Symptoms

- Alert firing on `ferrite_memory_used_bytes` exceeding threshold
- Increased eviction rate or OOM errors in logs
- Client errors: `OOM command not allowed when used memory > maxmemory`

## Investigation

```bash
# 1. Check current memory usage
ferrite-cli MEMORY USAGE
ferrite-cli INFO memory

# 2. Query Prometheus for memory trend
# ferrite_memory_used_bytes{instance="$INSTANCE"}
# rate(ferrite_evicted_keys_total[5m])

# 3. Check tier distribution
ferrite-cli MEMORY TIER-STATS
ferrite-cli INFO keyspace

# 4. Identify large keys
ferrite-cli MEMORY TOP-KEYS 20

# 5. Check for memory fragmentation
# Look at mem_fragmentation_ratio in INFO memory
# Values > 1.5 indicate significant fragmentation
```

## Remediation

**Immediate (>95% usage):**

1. **Enable eviction** if not set:
   ```bash
   ferrite-cli CONFIG SET maxmemory-policy allkeys-lru
   ```
2. **Enable tiered storage** to spill cold data to disk:
   ```bash
   ferrite-cli CONFIG SET tiered-storage-enabled yes
   ferrite-cli CONFIG SET tiered-storage-path /data/tier2
   ```
3. **Increase maxmemory** if headroom exists on the host:
   ```bash
   ferrite-cli CONFIG SET maxmemory <new_value>
   ```

**Follow-up:**

4. Review and delete unnecessary keys or TTL-less keys
5. Optimize data structures (e.g., use hashes for small objects)
6. If fragmentation is high, schedule a rolling restart during maintenance window

## Prevention

- Set `maxmemory` to 75% of available RAM
- Configure alerts at 70% (warning) and 85% (critical)
- Enable tiered storage for datasets expected to exceed memory
- Run `MEMORY TOP-KEYS` weekly to catch growth patterns
- Capacity-plan: track `ferrite_memory_used_bytes` trend over 30 days
