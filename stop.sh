#!/bin/bash
cd "$(dirname "$0")"
[ ! -f .env ] && { echo ".env missing"; exit 1; }
set -a; source .env; set +a

echo "Stopping ES and releasing RAM..."

# scale to 0 first so k8s doesn't restart the pod after we kill the process
kubectl scale statefulset elasticsearch -n "$NAMESPACE" --replicas=0 2>/dev/null || true

# kill any orphan ES JVM processes CRI-O left behind
killed=0
for pid in $(pgrep -f "org.elasticsearch" 2>/dev/null); do
  echo "  Killing orphan ES process $pid..."
  sudo kill -9 "$pid" 2>/dev/null && killed=$((killed+1)) || true
done
[ "$killed" -eq 0 ] && echo "  No orphan processes found."

# wait for pod to disappear
kubectl wait --for=delete pod --all -n "$NAMESPACE" --timeout=30s 2>/dev/null || true

echo ""
free -h | grep -E "^Mem"
echo "Done. ES is stopped."
