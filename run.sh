#!/bin/bash
set -u
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "[!] .env not found. Run ./setup.sh first."
  exit 1
fi

set -a; source .env; set +a

MAX_DURATION=${1:-${DEFAULT_DURATION:-1800}}
NS=$NAMESPACE
DESIRED_REPLICAS=$LOADER_REPLICAS

TS=$(date +%Y%m%d-%H%M%S)
OUT="$PWD/runs/run-$TS"
mkdir -p "$OUT"

echo "Run: $TS  Loaders: $DESIRED_REPLICAS  Max: ${MAX_DURATION}s"

do_cleanup() {
  if [ "${KEEP_ES_RUNNING:-false}" = "true" ]; then
    echo "[CLEANUP] Scaling loader to 0 (keeping ES running)..."
    kubectl scale deployment es-loader -n $NS --replicas=0 > /dev/null 2>&1 || true
    kubectl wait --for=delete pods -l app=es-loader -n $NS --timeout=30s 2>/dev/null || true
  else
    bash "$PWD/scripts/cleanup.sh"
  fi
}

if ! kubectl get namespace $NS > /dev/null 2>&1; then
  echo "[!] Namespace not found. Run ./setup.sh first."
  exit 1
fi

CURRENT=$(kubectl get deployment es-loader -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
if [ "${CURRENT:-0}" -lt $DESIRED_REPLICAS ]; then
  echo "Scaling loader to $DESIRED_REPLICAS..."
  kubectl scale deployment es-loader -n $NS --replicas=$DESIRED_REPLICAS > /dev/null
  kubectl rollout status deployment/es-loader -n $NS --timeout=120s
fi

{
  kubectl get pods -n $NS -o wide
  echo
  kubectl describe statefulset elasticsearch -n $NS
} > "$OUT/00-initial-state.txt" 2>&1

LOG_PIDS=()
for pod in $(kubectl get pods -n $NS -l app=es-loader --no-headers 2>/dev/null | awk '$3=="Running"{print $1}'); do
  kubectl logs -n $NS $pod -f --tail=200 > "$OUT/log-$pod.txt" 2>&1 &
  LOG_PIDS+=($!)
done

METRIC_FILE="$OUT/metrics.log"
SUMMARY_FILE="$OUT/summary.csv"
echo "timestamp,elapsed_s,node_cpu_m,node_mem_mi,es_cpu_m,es_mem_mi,loader_cpu_m,loader_mem_mi,total_docs" > "$SUMMARY_FILE"

START_TS=$(date +%s)

on_interrupt() {
  echo
  echo "Interrupted. Cleaning up..."
  for pid in "${LOG_PIDS[@]}"; do kill $pid 2>/dev/null; done
  finish_run
  exit 0
}
trap on_interrupt INT TERM

finish_run() {
  {
    kubectl get pods -n $NS -o wide
    echo
    kubectl exec -n $NS statefulset/elasticsearch -- curl -s localhost:9200/_cat/indices?v
  } > "$OUT/99-final-state.txt" 2>&1
  for pid in "${LOG_PIDS[@]}"; do kill $pid 2>/dev/null; done
  do_cleanup

  # Generate human-readable summary
  REPORT="$OUT/SUMMARY.txt"
  bash "$PWD/scripts/analyze-run.sh" "$OUT" | tee "$REPORT"

  echo
  echo "EXPERIMENT COMPLETE"
  echo "Results: $OUT"
  echo "Summary saved to: $REPORT"
  ls -1 "$OUT" | sed 's/^/  - /'
}

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if [ $ELAPSED -gt $MAX_DURATION ]; then
    echo "Timeout."
    break
  fi

  TIMESTAMP=$(date +%H:%M:%S)
  NODE_LINE=$(kubectl top nodes --no-headers 2>/dev/null | head -1)
  NODE_CPU=$(echo "$NODE_LINE" | awk '{print $2}' | sed 's/m$//')
  NODE_MEM=$(echo "$NODE_LINE" | awk '{print $4}' | sed 's/Mi$//')

  ES_LINE=$(kubectl top pods -n $NS --no-headers 2>/dev/null | grep elasticsearch)
  ES_CPU=$(echo "$ES_LINE" | awk '{gsub("m","",$2); print $2+0}')
  ES_MEM=$(echo "$ES_LINE" | awk '{gsub("Mi","",$3); print $3+0}')

  LOADER_LINES=$(kubectl top pods -n $NS --no-headers 2>/dev/null | grep es-loader)
  LOADER_CPU=$(echo "$LOADER_LINES" | awk '{gsub("m","",$2); sum+=$2} END {print sum+0}')
  LOADER_MEM=$(echo "$LOADER_LINES" | awk '{gsub("Mi","",$3); sum+=$3} END {print sum+0}')

  TOTAL_DOCS=$(kubectl exec -n $NS statefulset/elasticsearch -- curl -s localhost:9200/_cat/count?h=count 2>/dev/null | tr -d '[:space:]')

  {
    echo "=== $TIMESTAMP (elapsed=${ELAPSED}s) ==="
    kubectl top nodes 2>/dev/null
    kubectl top pods -n $NS 2>/dev/null
    echo "Total docs in ES: $TOTAL_DOCS"
    echo
  } >> "$METRIC_FILE"

  echo "$TIMESTAMP,$ELAPSED,$NODE_CPU,$NODE_MEM,$ES_CPU,$ES_MEM,$LOADER_CPU,$LOADER_MEM,$TOTAL_DOCS" >> "$SUMMARY_FILE"

  printf "[%s] elapsed=%-5ss node_cpu=%-6sm node_mem=%-6sMi es_cpu=%-5sm es_mem=%-6sMi docs=%s\n" \
    "$TIMESTAMP" "$ELAPSED" "$NODE_CPU" "$NODE_MEM" "$ES_CPU" "$ES_MEM" "$TOTAL_DOCS"

  sleep ${SAMPLE_INTERVAL:-5}
done

finish_run
