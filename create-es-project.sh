#!/bin/bash
set -e

PROJECT=~/work/elasticsearch-stress-test
mkdir -p "$PROJECT"/{manifests,scripts,runs}
cd "$PROJECT"

# ---------------- .env.example ----------------
cat > .env.example <<'ENV_END'
NAMESPACE=es-stress

# Elasticsearch sizing — for 30 GiB VM, 16Gi heap is the sweet spot
# (JVM heap should never exceed 50% of system RAM and never exceed ~31 GiB)
ES_HEAP_SIZE=16g
ES_MEM_REQUEST=18Gi
ES_MEM_LIMIT=20Gi
ES_CPU_REQUEST=2
ES_CPU_LIMIT=8

# Storage size for the ES data volume
ES_STORAGE=50Gi

# Index loader settings (drives sustained RAM usage)
LOADER_REPLICAS=2
LOADER_BATCH_SIZE=500
LOADER_DOCS_PER_BATCH=10000

# Default experiment duration (seconds)
DEFAULT_DURATION=1800
SAMPLE_INTERVAL=5
ENV_END

# ---------------- .gitignore ----------------
cat > .gitignore <<'GIT_END'
.env
.rendered/
runs/
*.swp
GIT_END

# ---------------- README.md ----------------
cat > README.md <<'README_END'
# Elasticsearch Stress Test on Kubernetes

Real-world RAM stress workload using Elasticsearch (single-node) with a
continuous log indexing loader. Designed to consume ~80% of host RAM via
JVM heap + OS file cache.

## Architecture

Loader pods → continuously index synthetic-but-realistic log documents → Elasticsearch
                                                                              ↓
                                                                  JVM heap fills steadily
                                                                  Index files cached in RAM
                                                                  Field data cache grows with queries

Companion to ffmpeg-stress-test (CPU stress). Run both for full CPU + RAM saturation.

## Quick Start
git clone <this-repo>
cd elasticsearch-stress-test
cp .env.example .env
./setup.sh
./run.sh

## Sizing

| VM RAM    | ES_HEAP_SIZE | Expected steady-state RAM use |
|-----------|--------------|-------------------------------|
| 30 GiB    | 16g          | ~24 GiB (80%)                 |
| 64 GiB    | 31g          | ~50 GiB (78%)                 |
| 256 GiB   | 31g (per node, 4 nodes) | ~200 GiB (78%) |

Rule: JVM heap ≤ 50% of node RAM, never exceed 31 GiB per node.

## License
MIT
README_END

# ---------------- manifests/namespace.yaml ----------------
cat > manifests/namespace.yaml <<'NS_END'
apiVersion: v1
kind: Namespace
metadata:
  name: __NAMESPACE__
NS_END

# ---------------- manifests/elasticsearch.yaml ----------------
cat > manifests/elasticsearch.yaml <<'ES_END'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: es-data
  namespace: __NAMESPACE__
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: __ES_STORAGE__
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: __NAMESPACE__
spec:
  serviceName: elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      initContainers:
      - name: fix-permissions
        image: busybox:1.36
        command: ["sh","-c","chown -R 1000:1000 /usr/share/elasticsearch/data"]
        volumeMounts:
        - name: data
          mountPath: /usr/share/elasticsearch/data
        securityContext:
          runAsUser: 0
      - name: increase-vm-max-map
        image: busybox:1.36
        command: ["sh","-c","sysctl -w vm.max_map_count=262144"]
        securityContext:
          privileged: true
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
        env:
        - name: discovery.type
          value: single-node
        - name: xpack.security.enabled
          value: "false"
        - name: ES_JAVA_OPTS
          value: "-Xms__ES_HEAP_SIZE__ -Xmx__ES_HEAP_SIZE__"
        - name: cluster.name
          value: stress-cluster
        - name: bootstrap.memory_lock
          value: "true"
        ports:
        - containerPort: 9200
          name: http
        - containerPort: 9300
          name: transport
        resources:
          requests:
            cpu: "__ES_CPU_REQUEST__"
            memory: "__ES_MEM_REQUEST__"
          limits:
            cpu: "__ES_CPU_LIMIT__"
            memory: "__ES_MEM_LIMIT__"
        volumeMounts:
        - name: data
          mountPath: /usr/share/elasticsearch/data
        securityContext:
          capabilities:
            add: ["IPC_LOCK"]
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: es-data
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: __NAMESPACE__
spec:
  selector:
    app: elasticsearch
  ports:
  - name: http
    port: 9200
    targetPort: 9200
ES_END

# ---------------- manifests/loader.yaml ----------------
cat > manifests/loader.yaml <<'LOADER_END'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: es-loader
  namespace: __NAMESPACE__
spec:
  replicas: __LOADER_REPLICAS__
  selector:
    matchLabels:
      app: es-loader
  template:
    metadata:
      labels:
        app: es-loader
    spec:
      containers:
      - name: loader
        image: python:3.11-slim
        command: ["bash","-c"]
        args:
        - |
          pip install --quiet elasticsearch faker requests
          python /scripts/loader.py
        env:
        - name: ES_HOST
          value: http://elasticsearch:9200
        - name: BATCH_SIZE
          value: "__LOADER_BATCH_SIZE__"
        - name: DOCS_PER_BATCH
          value: "__LOADER_DOCS_PER_BATCH__"
        resources:
          requests:
            cpu: "1"
            memory: "512Mi"
          limits:
            cpu: "2"
            memory: "1Gi"
        volumeMounts:
        - name: scripts
          mountPath: /scripts
      volumes:
      - name: scripts
        configMap:
          name: loader-script
LOADER_END

# ---------------- loader Python script (lives in ConfigMap) ----------------
cat > manifests/loader-configmap.yaml <<'CM_END'
apiVersion: v1
kind: ConfigMap
metadata:
  name: loader-script
  namespace: __NAMESPACE__
data:
  loader.py: |
    import os, time, random, string, json, signal, sys
    from elasticsearch import Elasticsearch, helpers
    from faker import Faker

    ES_HOST = os.environ.get('ES_HOST', 'http://elasticsearch:9200')
    BATCH_SIZE = int(os.environ.get('BATCH_SIZE', 500))
    DOCS_PER_BATCH = int(os.environ.get('DOCS_PER_BATCH', 10000))

    fake = Faker()
    es = None

    # Wait for ES
    for i in range(60):
        try:
            es = Elasticsearch([ES_HOST], request_timeout=10)
            if es.ping():
                print(f"Connected to ES at {ES_HOST}", flush=True)
                break
        except Exception as e:
            print(f"Waiting for ES... ({e})", flush=True)
            time.sleep(5)
    else:
        print("ES never came up", flush=True)
        sys.exit(1)

    def shutdown(signum, frame):
        print("[SHUTDOWN] exiting", flush=True)
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    LEVELS = ["DEBUG","INFO","WARN","ERROR","CRITICAL"]
    SERVICES = ["api","auth","payment","search","cart","checkout","analytics","notify","billing","fraud"]

    def gen_doc():
        return {
            "@timestamp": fake.iso8601(),
            "level": random.choice(LEVELS),
            "service": random.choice(SERVICES),
            "host": fake.hostname(),
            "user_id": random.randint(1, 1000000),
            "session_id": fake.uuid4(),
            "ip": fake.ipv4(),
            "user_agent": fake.user_agent(),
            "method": random.choice(["GET","POST","PUT","DELETE","PATCH"]),
            "path": fake.uri_path(),
            "status": random.choice([200,200,200,201,301,400,404,500]),
            "duration_ms": random.randint(1, 2000),
            "bytes": random.randint(100, 1000000),
            "message": fake.sentence(nb_words=20),
            "tags": random.sample(["prod","staging","beta","cache","slow","retry","auth","db"], k=3),
            "geo": {"country": fake.country_code(), "city": fake.city()},
            "trace_id": fake.uuid4(),
        }

    batch_num = 0
    total_docs = 0
    while True:
        index_name = f"logs-{time.strftime('%Y.%m.%d')}-batch{batch_num % 10}"
        actions = [{"_index": index_name, "_source": gen_doc()} for _ in range(DOCS_PER_BATCH)]
        try:
            ok, errors = helpers.bulk(es, actions, chunk_size=BATCH_SIZE, raise_on_error=False)
            total_docs += ok
            print(f"[BATCH {batch_num}] indexed {ok} docs (total {total_docs})", flush=True)

            # Run a few queries to populate caches and add CPU pressure
            es.search(index="logs-*", body={
                "size": 0,
                "aggs": {
                    "by_service": {"terms": {"field": "service.keyword", "size": 20}},
                    "by_status":  {"terms": {"field": "status", "size": 20}},
                    "avg_dur":    {"avg":   {"field": "duration_ms"}}
                }
            }, request_timeout=30)
        except Exception as e:
            print(f"[ERROR] {e}", flush=True)
            time.sleep(5)

        batch_num += 1
CM_END

# ---------------- setup.sh ----------------
cat > setup.sh <<'SETUP_END'
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
SETUP_END
chmod +x setup.sh

# ---------------- run.sh ----------------
cat > run.sh <<'RUN_END'
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
  echo "[CLEANUP] Scaling loader to 0..."
  kubectl scale deployment es-loader -n $NS --replicas=0 > /dev/null 2>&1 || true
  echo "[CLEANUP] Done. (Elasticsearch left running — use ./teardown.sh to delete it)"
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
  echo "EXPERIMENT COMPLETE  Results: $OUT"
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
RUN_END
chmod +x run.sh

# ---------------- teardown.sh ----------------
cat > teardown.sh <<'TEARDOWN_END'
#!/bin/bash
set -u
cd "$(dirname "$0")"
[ ! -f .env ] && { echo ".env missing"; exit 1; }
set -a; source .env; set +a

echo "This will DELETE the entire '$NAMESPACE' namespace and all ES data."
read -p "Continue? (yes/no): " ans
[ "$ans" = "yes" ] || exit 1

kubectl delete namespace "$NAMESPACE" --timeout=120s
rm -rf .rendered
echo "Done."
TEARDOWN_END
chmod +x teardown.sh

echo
echo "================================================================"
echo "  Project created at $PROJECT"
ls -la "$PROJECT"
echo "================================================================"
echo "Done."
