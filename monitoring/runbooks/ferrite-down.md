# Runbook: Ferrite Down

**Alerts:** `FerriteDown` (no response for >30s)

## Symptoms

- Clients receive connection refused or timeout errors.
- Prometheus scrape target is unreachable.
- Health check endpoint (`/health` or `PING`) returns no response.

## Impact

**Severity: Critical** — All reads and writes are failing. Dependent services will degrade.

## Triage

1. **Check process status:**

   ```bash
   # Docker
   docker compose ps ferrite
   docker compose logs --tail 100 ferrite

   # Kubernetes
   kubectl get pods -l app.kubernetes.io/name=ferrite -n ferrite
   kubectl describe pod <pod-name> -n ferrite
   kubectl logs <pod-name> -n ferrite --tail=200
   ```

2. **Check for OOM kills:**

   ```bash
   # Linux host
   dmesg | grep -i "oom\|killed"

   # Kubernetes
   kubectl get events -n ferrite --sort-by='.lastTimestamp' | grep -i kill
   ```

3. **Check disk space:**

   ```bash
   df -h /var/lib/ferrite/data
   ```

4. **Check port binding:**

   ```bash
   ss -tlnp | grep 6379
   ```

## Resolution

| Cause | Action |
|-------|--------|
| Process crashed | Restart: `systemctl restart ferrite` or `kubectl delete pod <name>` |
| OOM killed | Increase memory limit or reduce `max_memory` in config |
| Disk full | Free space (see `disk-full.md`), then restart |
| Port conflict | Kill conflicting process, then restart |
| Config error | Check logs for config parse errors, fix `ferrite.toml`, restart |

## Prevention

- Set memory limits below the OOM threshold (leave 20% headroom).
- Enable AOF persistence with `fsync=everysec` to survive restarts.
- Use a process supervisor (systemd, Kubernetes) for automatic restarts.
- Monitor with `FerriteDown` alert (fire after 30s of no scrape).
