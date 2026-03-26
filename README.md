# etcd-metrics-collector

Script for collecting and analyzing etcd latency metrics in HyperShift clusters
(OpenShift Hosted Control Planes).

## Problem it solves

In HyperShift environments, etcd runs as a StatefulSet on the management cluster
and uses PVCs provisioned via CSI. Storage IO latency issues directly impact etcd
stability, causing frequent leader elections and cluster instability.

This script collects critical metrics from all hosted clusters at once, calculates
percentiles, and classifies the severity of each etcd pod.

## Context: how IO stall kills etcd

etcd uses synchronous fsync on the Write-Ahead Log (WAL). Every write operation
must be acknowledged by the disk before proceeding. If storage takes longer than
the election timeout (default: 1000ms), the follower assumes the leader is dead
and triggers a new election.

The most dangerous pattern is not uniformly high latency, but the **bimodal
pattern**: an apparently healthy P99 (e.g. 2ms) with a catastrophic tail (hundreds
of operations above 512ms, dozens above 8 seconds). This pattern is the signature
of **periodic IO stall**, typically caused by:

- Snapshot operations on the storage controller (backup, replication, TI Pair sync)
- VM migrations running simultaneously with backup windows
- Queue depth saturation on the controller during peak periods
- Controller failover or multipath path switching

In Hitachi VSP environments with CSI, etcd PVCs share the same pools and
controllers as VM volumes. An intensive snapshot event impacts all volumes
simultaneously, which explains leader elections occurring in parallel across all
clusters.

## A note on heterogeneous impact

If pods in the same cluster show very different WAL tail latency, this points to
**uneven storage path exposure** - specific LUNs or controller ports are more
affected than others. A tell-tale sign: the pods with the *highest* leader change
count may actually have the *lowest* WAL stall, because they were being elected
repeatedly as healthy replacements for the pods that were stalling. Always cross-
reference leader changes with WAL >512ms and WAL >8192ms to identify which pods
were the actual IO victims.

## Metrics collected

| Metric | Red Hat limit | Meaning |
|---|---|---|
| WAL fsync P99 | < 10ms | Write latency on the Write-Ahead Log |
| WAL fsync P99.9 | < 25ms | WAL latency tail |
| WAL fsync >512ms | 0 ops | Operations with severe stall |
| Backend commit P99 | < 10ms | Commit latency on bbolt |
| Backend >512ms | 0 ops | Commits with severe stall |
| Leader changes | < 5 total | Leader elections (instability) |

## Requirements

- `bash` 4+
- `awk`
- `oc` authenticated to the management cluster with exec permission on etcd pods
- Read access to the `HostedControlPlane` resource in the hosted cluster namespaces

## Usage

```bash
chmod +x collect-etcd-metrics.sh
./collect-etcd-metrics.sh
```

The script automatically discovers all hosted clusters via `oc get hcp -A`.

## Expected output

```
==> Discovering hosted clusters via oc get hcp -A ...
==> Clusters found:
    namespace=my-cluster-ns  hcp=my-cluster

==> Cluster: my-cluster (my-cluster-ns)
  -> etcd-0
  +- etcd-0
  |  Leader changes    : 795
  |  WAL fsync avg     : 1.48ms
  |  WAL fsync P99     : 2.0ms
  |  WAL fsync P99.9   : 8.0ms
  |  WAL fsync >512ms  : 3402 ops  CRITICAL
  |  Backend P99       : 4.0ms
  |  Backend P99.9     : 16.0ms
  |  Backend >512ms    : 2213 ops  CRITICAL
  +- STATUS: CRITICAL
```

Raw files for each pod are saved under `./etcd-metrics-<timestamp>/` for later
analysis. Archive the directory (tar -czf) and preserve it alongside incident
reports as audit evidence.

## Classification criteria

| Status | Criteria |
|---|---|
| OK | Leader changes <= 10 and WAL >512ms = 0 |
| DEGRADED | Leader changes > 10 |
| CRITICAL | Leader changes > 100 or WAL >512ms > 10 |

## Interpreting results

**Low P99 with high tail** (e.g. P99=2ms, >512ms=3400 ops) is the classic pattern
of periodic IO stall. It does not indicate uniformly slow storage, but rather
periodic blocking events, typically associated with active backup windows, snapshots,
or ongoing VM migrations.

**All clusters CRITICAL simultaneously** indicates a common cause in the shared
storage infrastructure, not independent per-cluster failures.

**Inverse correlation between leader changes and WAL stall** in the same cluster
indicates heterogeneous storage path impact. Pods with high leader changes but low
WAL stall were being elected as replacements. The real IO victims are the pods with
high WAL >512ms and WAL >8192ms counts - those are the nodes the storage team
should investigate first.

## Resetting metrics

etcd metrics are cumulative counters since the last pod start. To reset (e.g. after
a fix, to establish a clean baseline):

```bash
# Restart pods one at a time - never more than one simultaneously
for i in 0 1 2; do
  oc delete pod etcd-${i} -n <hosted-cluster-namespace>
  sleep 30
done
```

The StatefulSet recreates each pod automatically. Wait at least 1 hour after
restarting before collecting a new baseline.

## Complementing the investigation

After running the script, collect OpenShift events for temporal correlation:

```bash
for NS in $(oc get hcp -A --no-headers | awk '{print $1}'); do
  echo "=== $NS ==="
  oc get events -n "$NS" --sort-by='.lastTimestamp' 2>/dev/null \
    | grep -iE "leader|etcd|timeout|slow" | tail -5
done
```

Correlate LeaderElection event timestamps with backup windows, snapshot operations,
and ongoing VM migrations on the storage side.

## Reference

Red Hat KB: etcd performance requirements
https://access.redhat.com/solutions/4770281
