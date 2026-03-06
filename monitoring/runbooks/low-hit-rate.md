# Runbook: Low Cache Hit Rate

**Alerts:** `FerriteLowHitRate` (<80% hit ratio), `FerriteEvictions` (>100/s)

## Symptoms

- `keyspace_hits / (keyspace_hits + keyspace_misses)` ratio is below threshold.
- Evictions counter is rising (data is being removed to make room).
- Backend systems report increased load (cache is not absorbing reads).

## Impact

**Severity: Medium** — Higher latency for reads and increased load on upstream data stores. Not an outage, but degrades performance.

## Triage

1. **Check hit rate and eviction stats:**

   ```bash
   ferrite-cli INFO stats
   # Look at: keyspace_hits, keyspace_misses, evicted_keys
   ```

2. **Check memory usage:**

   ```bash
   ferrite-cli INFO memory
   # Compare used_memory vs maxmemory
   ```

3. **Check key distribution and TTLs:**

   ```bash
   ferrite-cli DBSIZE
   ferrite-cli INFO keyspace
   ```

4. **Identify hot keys:**

   ```bash
   # If slow log is enabled
   ferrite-cli SLOWLOG GET 20
   ```

## Resolution

| Cause | Action |
|-------|--------|
| Insufficient memory | Increase `max_memory` or add nodes |
| Poor eviction policy | Switch to `allkeys-lru` or `volatile-lfu` |
| Keys too short-lived (low TTL) | Review TTL strategy; extend TTLs for stable data |
| Working set larger than cache | Scale horizontally or enable tiered storage |
| Cold start after restart | Pre-warm cache with common queries |

**Quick adjustments:**

```bash
# Change eviction policy at runtime
ferrite-cli CONFIG SET maxmemory-policy allkeys-lfu

# Increase memory limit
ferrite-cli CONFIG SET maxmemory 8589934592
```

## Prevention

- Size the cache to hold the working set (typically 80th percentile of access patterns).
- Use LFU eviction for workloads with uneven access frequency.
- Enable tiered storage to keep cold data on disk rather than evicting.
- Monitor hit rate trend over time — a gradual decline signals growing working set.
