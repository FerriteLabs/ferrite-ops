# Runbook: Failover Monitoring Alerts

## Overview

This runbook covers triage and resolution steps for Ferrite failover-related
Prometheus alerts. It is intended for on-call engineers responding to pages
from the `ferrite-cluster-alerts` rule group.

---

## Alert: FerriteClusterStateNotOk

**Severity:** critical

**Meaning:** The Ferrite cluster has entered a degraded state and is no longer
fully operational.

### Triage Steps

1. Check which nodes are reporting the alert:
   ```bash
   kubectl get pods -l app.kubernetes.io/name=ferrite -o wide
   ```
2. Inspect the cluster state from any healthy node:
   ```bash
   ferrite-cli CLUSTER INFO
   ```
3. Review recent pod events for OOMKills or restarts:
   ```bash
   kubectl describe pod <pod-name>
   ```

### Resolution

- If a node is in `FAIL` state, check its logs and restart if necessary.
- If slots are unassigned, run `ferrite-cli CLUSTER FIX` from a healthy node.
- Verify network policies are not blocking inter-node communication on port 16379.

---

## Alert: FerriteClusterNodeDown

**Severity:** critical

**Meaning:** One or more known cluster nodes are unreachable or not responding.

### Triage Steps

1. Identify the failing node:
   ```bash
   ferrite-cli CLUSTER NODES | grep fail
   ```
2. Check if the pod is running:
   ```bash
   kubectl get pod <pod-name> -o jsonpath='{.status.phase}'
   ```
3. Check persistent volume status to rule out storage issues.

### Resolution

- If the pod is `CrashLoopBackOff`, check logs for corruption or config errors.
- If the node was permanently lost, remove it from the cluster and add a
  replacement:
  ```bash
  ferrite-cli CLUSTER FORGET <node-id>
  ```
- After recovery, verify slot coverage:
  ```bash
  ferrite-cli CLUSTER INFO
  ```

---

## Alert: FerriteReplicationBroken

**Severity:** critical

**Meaning:** The number of connected replicas is below the expected count. A
failover may be needed or may have already occurred.

### Triage Steps

1. Check replication status:
   ```bash
   ferrite-cli INFO replication
   ```
2. Verify the replica pod is running and can reach the primary.
3. Check for network partitions between primary and replica pods.

### Resolution

- If a replica is lagging, it will usually catch up on its own. Monitor
  `ferrite_replication_lag_seconds`.
- If the replica has disconnected permanently, scale the StatefulSet back up
  and let it rejoin:
  ```bash
  kubectl scale statefulset ferrite --replicas=<desired>
  ```

---

## Escalation

If the alert persists after following the steps above, escalate to the
Ferrite platform team in the `#ferrite-oncall` Slack channel.
