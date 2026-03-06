# Runbook: Connection Saturation

**Alerts:** `FerriteHighConnectionCount` (>80% of max), `FerriteRejectedConnections` (>0/min)

## Symptoms

- Clients intermittently fail to connect.
- `INFO clients` shows `connected_clients` near `maxclients`.
- `rejected_connections` counter is incrementing.

## Impact

**Severity: High** — New client connections are being refused. Existing connections continue to work until they disconnect.

## Triage

1. **Check current connections:**

   ```bash
   ferrite-cli INFO clients
   # Look at: connected_clients, blocked_clients, maxclients
   ```

2. **Identify connection sources:**

   ```bash
   ferrite-cli CLIENT LIST
   # Group by addr to find noisy clients
   ```

3. **Check for connection leaks:**

   ```bash
   # Look for idle connections that should have been closed
   ferrite-cli CLIENT LIST | grep "idle=[0-9]\{4,\}"
   ```

## Resolution

| Cause | Action |
|-------|--------|
| Legitimate traffic spike | Increase `maxclients` in config |
| Connection leak in client app | Fix client code; enable `timeout` in ferrite.toml to auto-close idle connections |
| Too many monitoring connections | Reduce scrape concurrency or use connection pooling |
| Missing connection pooling | Implement connection pooling in clients (e.g., ioredis pool, Lettuce) |

**Immediate relief:**

```bash
# Kill idle connections older than 300 seconds
ferrite-cli CLIENT KILL IDLE 300

# Or increase the limit at runtime
ferrite-cli CONFIG SET maxclients 20000
```

## Prevention

- Set `timeout` in `ferrite.toml` to auto-disconnect idle clients (e.g., 300s).
- Use connection pooling in all client applications.
- Monitor `connected_clients` / `maxclients` ratio.
- Alert at 80% capacity to allow time to respond.
