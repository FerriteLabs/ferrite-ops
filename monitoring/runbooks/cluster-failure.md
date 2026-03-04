# Runbook: Cluster Failure

**Alerts:** `ClusterStateNotOk`, `ClusterNodeDown`, `ClusterSplitBrain`

## Symptoms

- `CLUSTERDOWN` errors from clients
- `ferrite_cluster_state` metric != `ok`
- Nodes unreachable or partitioned; clients getting `MOVED`/`ASK` redirects to dead nodes

## Investigation

```bash
# 1. Check cluster state
ferrite-cli CLUSTER INFO
# cluster_state: ok|fail
# cluster_slots_assigned, cluster_slots_ok, cluster_known_nodes

# 2. List all nodes and their status
ferrite-cli CLUSTER NODES
# Look for: fail, fail?, handshake, noaddr flags

# 3. Check for uncovered slots
ferrite-cli CLUSTER SLOTS
# Verify all 16384 slots are assigned and served

# 4. Check gossip state from multiple nodes
for node in $NODE_IPS; do
  echo "=== $node ==="
  ferrite-cli -h $node CLUSTER INFO | grep cluster_state
  ferrite-cli -h $node CLUSTER NODES | grep -E "fail|handshake"
done

# 5. Check network partitions
# Ping between all node pairs
for src in $NODE_IPS; do
  for dst in $NODE_IPS; do
    echo "$src -> $dst: $(ssh $src ping -c 1 -W 1 $dst | grep loss)"
  done
done
```

## Remediation

**ClusterNodeDown:**

1. Check if the node process is running; restart if crashed:
   ```bash
   systemctl status ferrite@<port>
   systemctl restart ferrite@<port>
   ```
2. If node won't recover, trigger manual failover from its replica:
   ```bash
   ferrite-cli -h <replica_of_failed_node> CLUSTER FAILOVER
   ```

**ClusterStateNotOk (uncovered slots):**

3. If a primary is down with no replica, reassign slots temporarily:
   ```bash
   ferrite-cli -h <healthy_node> CLUSTER ADDSLOTS <slot_range>
   ```
4. Or bring a new node online and replicate:
   ```bash
   ferrite-cli -h <new_node> CLUSTER MEET <existing_node> <port>
   ferrite-cli -h <new_node> CLUSTER REPLICATE <failed_primary_id>
   ```

**ClusterSplitBrain:**

5. Identify which partition has the majority of nodes
6. Resolve network partition (check firewalls, security groups, DNS)
7. Nodes in minority partition will rejoin automatically once network heals
8. If stale nodes persist, remove and re-add them:
   ```bash
   ferrite-cli CLUSTER FORGET <stale_node_id>
   ferrite-cli -h <stale_node> CLUSTER RESET SOFT
   ferrite-cli -h <stale_node> CLUSTER MEET <primary> <port>
   ```

## Prevention

- Deploy minimum 3 primary nodes, each with 1+ replica
- Use pod anti-affinity rules (Kubernetes) or spread across AZs
- Set `cluster-node-timeout` to 5000ms (balance detection speed vs. flapping)
- Monitor `ferrite_cluster_state` and `ferrite_cluster_known_nodes`
- Run `CLUSTER INFO` health checks in your readiness probes
