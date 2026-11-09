# flannel-startup-contention

Getting Flannel up fast after a reboot on Kubernetes nodes that use **iptables-legacy** and carry **many
Services**, plus a script to build that load in a test cluster.

## The problem

With tens of thousands of Services, kube-proxy (iptables mode, e.g. Kubernetes 1.23) writes NAT tables with tens
or hundreds of thousands of lines. iptables-legacy rewrites a whole table for every command under one global lock
(`/run/xtables.lock`), so after a reboot:

1. Flannel reaches the API through the `kubernetes` Service ClusterIP (client-go in-cluster config), which only
   works once kube-proxy has programmed it. Flannel's first container times out after 30 s and crashes.
2. Once kube-proxy has loaded its big table, each of Flannel's iptables commands is slow and waits behind every
   other command (kube-proxy's full restores, CNI `portmap` setup/teardown). Flannel can take many minutes.
3. Killing lock holders to "make room" backfires: killing kube-proxy's restores keeps the ClusterIP unusable, and
   killing `portmap` during CNI DEL fails teardowns (`failed to destroy network ... signal: killed`), leaving pods
   stuck `Terminating` and leaking `CNI-DN-*` chains.

## The fix

Two parts:

**1. Let Flannel (and Multus) reach the API directly.** On every container and init container of their
DaemonSets:

```yaml
env:
- name: KUBERNETES_SERVICE_HOST
  value: <API endpoint, e.g. the host in /etc/kubernetes/kubelet.conf>   # must be in the API server certificate
- name: KUBERNETES_SERVICE_PORT
  value: "6443"
```

**2. `flannel-startup-hold`:** a small boot script that freezes kube-proxy's cgroup until Flannel has written
`/run/flannel/subnet.env`, so Flannel programs its rules while the NAT table is still small. It holds for at most
120 s, never freezes kube-proxy while one of its iptables commands runs (it may hold the lock), always thaws on
exit, and kills nothing. Works with cgroup v1 (`freezer.state`) and v2 (`cgroup.freeze`).

Part 1 is required for part 2: without it Flannel needs kube-proxy's ClusterIP rule, and holding kube-proxy would
stall Flannel instead.

### Results (lab: 3 nodes, Kubernetes 1.23, containerd 1.4, iptables-legacy, 25,000 Services, heavy contention)

Flannel ready, seconds after kubelet start, with part 1 in place:

| boot | no script | flannel-startup-hold |
|---|---|---|
| Flannel starts first | 13, 25 | 39, 20 |
| kube-proxy starts first | **243**, 32 | **32, 50** |

Without part 2 the outcome depends on who wins the boot race; with it, Flannel was fast every time (kube-proxy held
9-13 s when it started first). For comparison, a kill-based guard without part 1 took 211-238 s for Flannel and
caused 100-600 failed CNI teardowns per boot.

## Install

```sh
install -m 0755 flannel-startup-hold /usr/local/sbin/flannel-startup-hold
install -m 0644 flannel-startup-hold.service /etc/systemd/system/flannel-startup-hold.service
systemctl daemon-reload
systemctl enable flannel-startup-hold.service   # runs once per boot, after kubelet
```

Logs: `journalctl -t kube-flannel-startup`.

## Test load: `load-cluster.sh`

Builds a heavily loaded cluster to reproduce this, all in one namespace:

- 80 pause pods on `NODE` (the node you will reboot), the first 2 with 4 hostPorts each
- a 3-replica StatefulSet `pod` on `NODE`
- backend pods on the other nodes and 25,000 Services; ~17.8k of them get one endpoint off `NODE`, so `NODE`'s NAT
  table stays full while it reboots

```sh
NODE=worker-1 ./load-cluster.sh up    # create
./load-cluster.sh status               # Service count, pods per node and state
./load-cluster.sh down                 # delete the namespace (25k Services take a few minutes to go)
```

Settings via environment: `NS`, `SERVICES`, `SVC_GROUPS`, `BACKEND_GROUPS`, `WORK_PODS`, `HOSTPORT_PODS`,
`BATCH`. hostPorts start at 20004.

## Diagnosing a slow boot

```sh
kubectl -n kube-system logs <kube-proxy pod> | grep -c 'holding the xtables lock'   # kube-proxy starved?
iptables-save -t nat | grep -c 'default/kubernetes:https'                          # 0 = Flannel can't reach the API
iptables-save -t nat | grep -c '^:CNI-DN-'                                         # >> hostPort pods = leaked teardowns
journalctl -u kubelet | grep -E 'KillPodSandbox|failed to destroy network'         # wedged CNI DELs
```
