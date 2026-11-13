# flannel-startup-contention

Getting Flannel up first after a reboot on Kubernetes nodes that use **iptables-legacy** and carry **many
Services**, plus a script to build that load in a test cluster.

## The problem

With tens of thousands of Services, kube-proxy (iptables mode, e.g. Kubernetes 1.23) writes NAT tables with tens
or hundreds of thousands of lines. iptables-legacy rewrites a whole table for every command under one global lock
(`/run/xtables.lock`), so after a reboot:

1. Flannel reaches the API through the `kubernetes` Service ClusterIP, which only works once kube-proxy has
   programmed it. Flannel's first container times out after 30 s and crashes.
2. Once kube-proxy has loaded its big table, each of Flannel's iptables commands is slow and waits behind every
   other command (kube-proxy's restores, CNI `portmap` setup/teardown for hostPort pods). Flannel can take many
   minutes, and no pod can start without it.
3. With many hostPort pods, their `portmap` calls on the full table exceed kubelet's 2-minute limit, never finish,
   and leak `CNI-DN-*` chains.

## The fix

**1. Let Flannel (and Multus) reach the API directly.** On every container and init container of their
DaemonSets:

```yaml
env:
- name: KUBERNETES_SERVICE_HOST
  value: <API endpoint, e.g. the host in /etc/kubernetes/kubelet.conf>   # must be in the API server certificate
- name: KUBERNETES_SERVICE_PORT
  value: "6443"
```

Also pull the Flannel and pause images before kubelet starts, so Flannel is not waiting on a registry.

**2. `flannel-startup-hold`**, one script and one systemd unit on the node. Until Flannel has written
`/run/flannel/subnet.env` (it does that after its rules are in), or a time limit has passed, it:

- **freezes kube-proxy** (cgroup v1 freezer) from the moment it starts, and
- **gates the CNI `portmap` plugin**, the only CNI plugin here that runs iptables: teardown (DEL) succeeds at once,
  setup (ADD) answers "try again later".

When Flannel is ready the gate is removed first, the pods' first CNI calls run on the still-small table, and
kube-proxy is thawed once no `portmap` has run for 20 s (60 s at most). Nothing is killed.

### Safety properties

- **The xtables lock cannot be left stuck.** kube-proxy is frozen only while the script itself holds the lock, and
  the lock is released only after the kernel reports the cgroup `FROZEN`; otherwise it is thawed again.
- **Nothing is written to disk.** The gate is a shell stub in a tmpfs under `/run`, bind-mounted read-only over
  `/opt/cni/bin/portmap`; the real plugin stays untouched underneath. A reboot always restores the node.
- **The gate cannot break pod creation.** It is checked against the real plugin before and after mounting and is
  removed at once if anything differs. It opens by itself when Flannel is ready or the time limit passes, even if
  the script is gone.
- **kube-proxy cannot stay frozen.** The script releases on any exit; the unit's `ExecStopPost` releases if it is
  killed; a one-shot systemd timer, armed before anything is frozen and running a copy of the script kept in
  memory, releases 30 s after the limit whatever happened.
- **Stopping, killing or restarting the service is harmless.** A stop releases everything. A killed service is
  restarted at once (`Restart=on-failure`) and takes the hold up again, until the same deadline the first start of
  the boot set. The script holds only when started by systemd.
- **Fail open.** After `FLANNEL_HOLD_MAX_SECONDS` (default 600) everything is released, Flannel ready or not.

### Limits

- Requires cgroup v1, kube-proxy as a pod, and kubelet/containerd in the host mount namespace.
- While the service is stopped, and after the time limit, the node is unprotected.
- Only `portmap` is gated; another CNI plugin that runs iptables would not be held.
- Nothing may write `/opt/cni/bin/portmap` during boot (the gate is a read-only mount over it).
- Without the env vars of part 1 the script still works (kube-proxy runs until the Service IP answers, then is
  held), but Flannel then starts on the full table and nodes with many hostPort pods may not come up.

### Lab results

3 nodes, Kubernetes 1.23.4, containerd 1.4, iptables-legacy, cgroup v1, 25,000 Services, part 1 in place. "Up" =
all pods Running, seconds after the reboot.

| boot | result |
|---|---|
| no script, 80 hostPort pods, Flannel 4 min late | not up after 805 s; 10,625 CNI iptables commands before Flannel |
| script, 2 hostPort pods | up in 87-115 s |
| script, 80 hostPort pods | up in 74-102 s |
| script, 80 hostPort pods, 128 busy CPU loops + 200 lock-hammer loops | up in 90-146 s |
| script, 80 hostPort pods, Flannel 4 min late | up in 283-305 s |
| script, all of the above at once, Flannel 4 min / 400 s late | up in 305 s / 453 s |

In every run with the script in control: 0 CNI iptables commands before Flannel was ready, and no kube-proxy
process frozen while holding the lock (hundreds of stress cycles, also under 64 lock-hammer loops and 32 busy CPU
loops). kube-proxy is thawed 20-60 s after Flannel is ready.

Deliberate disruptions during the boot, each with the node coming up and nothing left frozen or mounted:

| disruption | outcome |
|---|---|
| service killed (`kill -9`) | restarted in about 1 s, hold resumed |
| `systemctl restart`, 8 rounds of stop / start / kill (8 hostPort pods) | hold resumed each time |
| script deleted from disk, then service killed | timer thawed kube-proxy from the memory copy 30 s after the limit |
| service killed or restarted, kube-proxy container removed, Flannel killed - right after Flannel was ready | up in 101-283 s |
| frozen kube-proxy pod deleted or its container removed | replacement held within about a second |
| Flannel killed three times before it was ready | up in 115 s |
| kubelet restarted right after Flannel was ready | up in 110 s; the restart itself leaks `CNI-DN` chains |
| containerd restarted, rogue lock holder for 200 s, reboot or hard crash during the hold | node came up |

Runs that did not come up, all with 80 hostPort pods or extreme lock contention: Flannel later than the time limit;
repeated `systemctl stop` during the first minutes (each stop releases kube-proxy, which then loads its table).

## Install

```sh
install -m 0755 flannel-startup-hold /usr/local/sbin/flannel-startup-hold
install -m 0644 flannel-startup-hold.service /etc/systemd/system/flannel-startup-hold.service
systemctl daemon-reload
systemctl enable flannel-startup-hold.service   # starts before kubelet on every boot
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
