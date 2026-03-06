# Runbook: Slow Commands

**Alerts:** `FerriteSlowCommands` (>10 slow commands/min)

## Symptoms

- P99 latency spikes for specific command types.
- Slow log entries accumulating.
- Downstream services report intermittent timeouts.

## Impact

**Severity: Medium** — Individual slow commands block the event loop on their shard, causing tail-latency spikes for co-located keys.

## Triage

1. **Check slow log:**

   ```bash
   ferrite-cli SLOWLOG GET 20
   # Shows: timestamp, duration (μs), command, arguments
   ```

2. **Identify problematic commands:**

   ```bash
   ferrite-cli SLOWLOG GET 100 | sort -k3 -rn | head -10
   ```

3. **Common slow command patterns:**

   | Pattern | Typical Cause |
   |---------|---------------|
   | `KEYS *` | Full keyspace scan — never use in production |
   | `SORT` on large lists | O(N+M*log(M)) — use sorted sets instead |
   | `SMEMBERS` on huge sets | O(N) — use `SSCAN` for large sets |
   | `HGETALL` on huge hashes | O(N) — use `HSCAN` or specific `HGET` |
   | `LRANGE 0 -1` on long lists | O(N) — paginate with smaller ranges |

4. **Check if it's a data-size issue:**

   ```bash
   ferrite-cli DEBUG OBJECT <key>
   # Check serializedlength for large values
   ```

## Resolution

| Cause | Action |
|-------|--------|
| `KEYS` in production | Replace with `SCAN` cursor iteration |
| Large collection operations | Paginate: `SSCAN`, `HSCAN`, `ZSCAN`, `LRANGE` with ranges |
| Large values | Break into smaller keys or use hash fields |
| Complex Lua scripts | Optimize script, reduce data touched per call |
| Missing index for search | Add secondary index for search queries |

**Immediate relief:**

```bash
# Lower the slow log threshold to catch more queries
ferrite-cli CONFIG SET slowlog-log-slower-than 5000

# Increase slow log retention
ferrite-cli CONFIG SET slowlog-max-len 256
```

## Prevention

- Ban `KEYS` in production (use `SCAN` instead).
- Set `rename-command KEYS ""` if needed.
- Profile with `SLOWLOG` regularly.
- Set appropriate slow log thresholds (10ms default).
- Design data models for O(1) or O(log N) access patterns.
