#!/bin/bash
# Manual cleanup — fully releases all RAM/CPU held by Elasticsearch
set -u

cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo ".env missing"; exit 1; }
set -a; source .env; set +a

NS=$NAMESPACE

echo "[CLEANUP] === Starting cleanup for $NS ==="

# Step 1: Scale workloads to 0
echo "[CLEANUP] Scaling loader and ES to 0..."
kubectl scale deployment es-loader -n $NS --replicas=0 > /dev/null 2>&1 || true
kubectl scale statefulset elasticsearch -n $NS --replicas=0 > /dev/null 2>&1 || true

# Step 2: Brief grace wait
echo "[CLEANUP] Waiting up to 30s for graceful termination..."
kubectl wait --for=delete pods -l app=es-loader -n $NS --timeout=30s 2>/dev/null || true
kubectl wait --for=delete pods -l app=elasticsearch -n $NS --timeout=30s 2>/dev/null || true

# Step 3: Force-delete any pod still terminating
STUCK=$(kubectl get pods -n $NS --no-headers 2>/dev/null | grep Terminating | awk '{print $1}')
if [ -n "$STUCK" ]; then
  echo "[CLEANUP] Force-deleting stuck pods: $STUCK"
  for pod in $STUCK; do
    kubectl delete pod $pod -n $NS --grace-period=0 --force 2>/dev/null || true
  done
  sleep 3
fi

# Step 4: Kill leftover ES JVM if still running on host
JVM_PIDS=$(ps aux | grep "Xms${ES_HEAP_SIZE}" | grep -v grep | awk '{print $2}')
if [ -n "$JVM_PIDS" ]; then
  echo "[CLEANUP] JVM still running (PIDs: $JVM_PIDS) — killing to release ${ES_HEAP_SIZE}..."
  sudo kill -9 $JVM_PIDS 2>/dev/null || true
  sleep 2
fi

# Step 5: Drop OS page cache for clean baseline
echo "[CLEANUP] Dropping OS page cache..."
sudo sync 2>/dev/null || true
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

# Step 6: Report
echo
echo "[CLEANUP] === Final state ==="
kubectl get pods -n $NS 2>/dev/null
echo
free -h
echo
echo "[CLEANUP] Done. ES data volume preserved. Use ./teardown.sh to delete fully."
