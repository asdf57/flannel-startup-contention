#!/usr/bin/env bash
# load-cluster.sh up|down|status - load a cluster like the Flannel reboot tests:
#   - WORK_PODS pause pods pinned to NODE (the node you reboot), the first HOSTPORT_PODS of them with 4 hostPorts each
#   - a 3-replica StatefulSet "pod" on NODE (pod-0, pod-1, pod-2)
#   - BACKEND_GROUPS backend pods on the OTHER nodes; SERVICES Services spread over SVC_GROUPS selectors, so Services whose
#     group has a backend get one endpoint (off NODE, so NODE's NAT table stays full while it reboots) and the rest none
# Everything lives in namespace NS; "down" deletes that namespace.
#
#   NODE=worker-1 ./load-cluster.sh up
#   ./load-cluster.sh down
set -euo pipefail

NS=${NS:-load-test}
SERVICES=${SERVICES:-25000}
SVC_GROUPS=${SVC_GROUPS:-80}    # Services are spread over this many selectors
BACKEND_GROUPS=${BACKEND_GROUPS:-57}  # groups that get a backend pod (57/80 of 25k ~= 17.8k Services with endpoints)
WORK_PODS=${WORK_PODS:-80}
HOSTPORT_PODS=${HOSTPORT_PODS:-2}
BATCH=${BATCH:-500}             # Services per kubectl create

pause='registry.k8s.io/pause:3.6'

up() {
  : "${NODE:?set NODE to the node you will reboot}"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  echo "work pods on $NODE ($HOSTPORT_PODS with hostPorts)"
  for i in $(seq 1 "$WORK_PODS"); do
    ports="- {containerPort: 8080}"
    if (( i <= HOSTPORT_PODS )); then
      b=$((20000 + i * 4))
      ports="- {containerPort: 8080, hostPort: $b}
        - {containerPort: 8443, hostPort: $((b + 1))}
        - {containerPort: 9080, hostPort: $((b + 2))}
        - {containerPort: 9090, hostPort: $((b + 3))}"
    fi
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: work-$i, namespace: $NS}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: work-$i}}
  template:
    metadata: {labels: {app: work-$i}}
    spec:
      nodeSelector: {kubernetes.io/hostname: $NODE}
      enableServiceLinks: false   # thousands of Services would otherwise flood the env (E2BIG)
      terminationGracePeriodSeconds: 1
      containers:
      - name: pause
        image: $pause
        resources: {requests: {cpu: 1m, memory: 4Mi}}
        ports:
        $ports
EOF
  done | kubectl apply -f -

  echo "StatefulSet pod (pod-0..2) on $NODE"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata: {name: pod, namespace: $NS}
spec: {clusterIP: None, selector: {app: pod}, ports: [{name: a, port: 80, targetPort: 8080}]}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: pod, namespace: $NS}
spec:
  serviceName: pod
  replicas: 3
  selector: {matchLabels: {app: pod}}
  template:
    metadata: {labels: {app: pod}}
    spec:
      nodeSelector: {kubernetes.io/hostname: $NODE}
      enableServiceLinks: false
      terminationGracePeriodSeconds: 1
      containers:
      - {name: pause, image: $pause, ports: [{containerPort: 8080}], resources: {requests: {cpu: 1m, memory: 4Mi}}}
EOF

  echo "backend pods for $BACKEND_GROUPS of $SVC_GROUPS groups (off $NODE)"
  for g in $(seq 1 "$BACKEND_GROUPS"); do
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend-$g, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: backend-$g}}
  template:
    metadata: {labels: {app: backend-$g, group: "g$g"}}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions: [{key: kubernetes.io/hostname, operator: NotIn, values: [$NODE]}]
      tolerations:   # allow control-plane nodes too
      - {key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule}
      - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      enableServiceLinks: false
      terminationGracePeriodSeconds: 1
      containers:
      - {name: pause, image: $pause, ports: [{containerPort: 8080}], resources: {requests: {cpu: 1m, memory: 4Mi}}}
EOF
  done | kubectl apply -f -

  echo "$SERVICES Services, $BATCH per request"
  for ((s = 1; s <= SERVICES; s += BATCH)); do
    e=$(( s + BATCH - 1 > SERVICES ? SERVICES : s + BATCH - 1 ))
    {
      echo 'apiVersion: v1'; echo 'kind: List'; echo 'items:'
      for i in $(seq "$s" "$e"); do
        printf -- '- {apiVersion: v1, kind: Service, metadata: {name: svc-%d, namespace: %s}, spec: {selector: {group: "g%d"}, ports: [{port: 80, targetPort: 8080}]}}\n' \
          "$i" "$NS" $(( (i - 1) % SVC_GROUPS + 1 ))
      done
    } | kubectl create -f - >/dev/null
    printf '\r  %d / %d' "$e" "$SERVICES"
  done
  echo
  status
}

down() {
  # Deleting the namespace removes everything above; 25k Services take a few minutes to go.
  kubectl delete namespace "$NS" --wait=false --ignore-not-found
  echo "deleting namespace $NS in the background; watch: kubectl get ns $NS"
}

status() {
  echo "services: $(kubectl -n "$NS" get svc --no-headers 2>/dev/null | wc -l)"
  echo "pods by node and state:"
  kubectl -n "$NS" get pods -o wide --no-headers 2>/dev/null | awk '{print "  " $7, $3}' | sort | uniq -c
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: NODE=<node> $0 up | $0 down | $0 status" >&2; exit 2 ;;
esac
