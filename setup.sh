#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "[!] .env not found. Copying from .env.example..."
  cp .env.example .env
  echo "[!] Edit .env if needed, then re-run ./setup.sh"
  exit 1
fi

set -a; source .env; set +a

echo "Setup: namespace=$NAMESPACE  heap=$ES_HEAP_SIZE  loaders=$LOADER_REPLICAS"

render() {
  sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__ES_HEAP_SIZE__|$ES_HEAP_SIZE|g" \
      -e "s|__ES_MEM_REQUEST__|$ES_MEM_REQUEST|g" \
      -e "s|__ES_MEM_LIMIT__|$ES_MEM_LIMIT|g" \
      -e "s|__ES_CPU_REQUEST__|$ES_CPU_REQUEST|g" \
      -e "s|__ES_CPU_LIMIT__|$ES_CPU_LIMIT|g" \
      -e "s|__ES_STORAGE__|$ES_STORAGE|g" \
      -e "s|__LOADER_REPLICAS__|$LOADER_REPLICAS|g" \
      -e "s|__LOADER_BATCH_SIZE__|$LOADER_BATCH_SIZE|g" \
      -e "s|__LOADER_DOCS_PER_BATCH__|$LOADER_DOCS_PER_BATCH|g" \
      "$1" > "$2"
}

mkdir -p .rendered
render manifests/namespace.yaml         .rendered/namespace.yaml
render manifests/elasticsearch.yaml     .rendered/elasticsearch.yaml
render manifests/loader-configmap.yaml  .rendered/loader-configmap.yaml
render manifests/loader.yaml            .rendered/loader.yaml

echo "[1/4] Namespace..."
kubectl apply -f .rendered/namespace.yaml

echo "[2/4] Elasticsearch (this takes 1-2 min)..."
kubectl apply -f .rendered/elasticsearch.yaml
echo "Waiting for ES pod to be ready..."
kubectl wait --for=condition=ready pod -l app=elasticsearch -n "$NAMESPACE" --timeout=300s

echo "[3/4] Loader ConfigMap..."
kubectl apply -f .rendered/loader-configmap.yaml

echo "[4/4] Loader (initially scaled to 0)..."
kubectl apply -f .rendered/loader.yaml
kubectl scale deployment es-loader -n "$NAMESPACE" --replicas=0

echo
echo "Setup complete. Next: ./run.sh"
