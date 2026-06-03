# Elasticsearch Stress Test on Kubernetes

Real-world RAM stress workload using Elasticsearch (single-node) with a
dynamic load generator. Designed to consume ~80% of host RAM via JVM heap
+ OS file cache, with a P-controller that holds RAM at a configurable target.

## Architecture

```
fire-load.py  →  bulk index synthetic docs  →  Elasticsearch (StatefulSet)
     ↑                                               ↓
P-controller throttles write rate          JVM heap pre-committed (static)
to hold RAM near target %                  Lucene MMap fills OS page cache
     ↓                                               ↓
cleanup_indices() + stop.sh          RAM released cleanly on finish
```

Companion to ffmpeg-stress-test (CPU stress). Run both for full CPU + RAM saturation.

---

## Quick Start

```bash
git clone <this-repo>
cd elasticsearch-stress-test
cp .env.example .env          # edit if needed

# Install Python deps
python3 -m venv .venv
source .venv/bin/activate
pip install 'elasticsearch>=8,<9' faker

# Deploy ES
./setup.sh

# Run a stress test (5 min, 8 threads, 78% RAM target)
python3 scripts/fire-load.py --host http://localhost:30920 \
    --target-ram 78 --duration 5 --threads 8 --yes
```

`fire-load.py` auto-deletes indices and calls `./stop.sh` when it finishes — no manual cleanup needed.

---

## Primary Workflow

| Step | Command | What it does |
|---|---|---|
| Deploy | `./setup.sh` | Wipes previous deployment (PVCs included), deploys fresh ES with static heap |
| Test | `python3 scripts/fire-load.py [flags]` | Runs load, holds RAM at target, cleans up on exit |
| Stop early | `./stop.sh` | Scales ES to 0, kills any orphan JVM processes, frees RAM |
| Tear down | `./teardown.sh` | Deletes entire namespace and all data |

### fire-load.py flags

| Flag | Default | Description |
|---|---|---|
| `--host` | `http://localhost:30920` | ES endpoint |
| `--target-ram` | prompts | RAM % target (e.g. `78`) |
| `--duration` | prompts | Experiment duration in minutes (timer starts after warmup) |
| `--threads` | prompts | Parallel indexing threads (4–16 recommended) |
| `--warmup` | `0` | Minutes to index at full throttle before the timed experiment |
| `--yes` | off | Skip confirmation prompt |

---

## How RAM Targeting Works

Elasticsearch consumes RAM in two ways:

1. **JVM heap** — controlled by `ES_HEAP_SIZE`. Used for indexes, query caches, aggregations.
2. **OS page cache** — Lucene MMap'd segment files cached by the kernel. Grows with indexed data.

The heap is configured as **static** (`-Xms == -Xmx`), so the full heap is pre-committed at pod startup. RAM usage is high immediately — at `ES_HEAP_SIZE=16g` on a 45 GiB node, RAM sits at ~80% before a single document is indexed.

An optional `--warmup` phase runs workers at full throttle for N minutes before the timed experiment begins. This lets OS page cache and query caches fill before the P-controller takes over. The experiment timer only starts after warmup completes, so `--duration` always reflects actual experiment time.

`fire-load.py` then runs a P-controller that throttles write throughput to hold RAM near the configured target:

```
throttle = clamp(throttle + (target_ram% - actual_ram%) × 0.04, 0.05, 1.0)
```

When RAM exceeds the target, writes slow down. When below, writes speed up.

**Sizing rules:**
- JVM heap should never exceed **50% of node RAM**
- JVM heap should never exceed **31 GiB** (above this, JVM compressed pointers stop working)
- For higher targets on a large server, run multiple ES instances in separate namespaces

---

## Configuration

All sizing is controlled by `.env`. You do not need to edit YAML manifests.

### `.env` variables

| Variable | Purpose | Tuning rule |
|---|---|---|
| `NAMESPACE` | Kubernetes namespace | Leave as `es-stress` for single instance |
| `ES_HEAP_SIZE` | JVM heap (`-Xms` and `-Xmx`) | 50% of VM RAM, max `31g` |
| `ES_MEM_REQUEST` | K8s pod memory request | `ES_HEAP_SIZE + 2 GiB` |
| `ES_MEM_LIMIT` | K8s pod memory limit | `ES_HEAP_SIZE + 4 GiB` |
| `ES_CPU_REQUEST` | Guaranteed CPU cores | ~25% of VM vCPUs |
| `ES_CPU_LIMIT` | Hard CPU ceiling | ~50% of VM vCPUs |
| `ES_STORAGE` | PVC size for index data | 4× heap size minimum |
| `LOADER_REPLICAS` | Number of loader pods (legacy) | Not used by fire-load.py |
| `DEFAULT_DURATION` | Default seconds for `./run.sh` | 1800 (30 min) |
| `SAMPLE_INTERVAL` | Metric sampling cadence | 5 seconds |

### Quick Sizing Cheat Sheet

#### 16 GiB / 8 vCPU
```env
ES_HEAP_SIZE=8g
ES_MEM_REQUEST=10Gi
ES_MEM_LIMIT=12Gi
ES_CPU_REQUEST=2
ES_CPU_LIMIT=4
ES_STORAGE=32Gi
```
**Expected RAM use: ~80% from startup**

#### 30–45 GiB / 16 vCPU
```env
ES_HEAP_SIZE=16g
ES_MEM_REQUEST=18Gi
ES_MEM_LIMIT=20Gi
ES_CPU_REQUEST=2
ES_CPU_LIMIT=8
ES_STORAGE=50Gi
```
**Expected RAM use: ~80% from startup**

#### 64 GiB / 32 vCPU
```env
ES_HEAP_SIZE=31g
ES_MEM_REQUEST=33Gi
ES_MEM_LIMIT=36Gi
ES_CPU_REQUEST=4
ES_CPU_LIMIT=16
ES_STORAGE=200Gi
```
**Expected RAM use: ~78% from startup**

#### 128 GiB+ / 64+ vCPU
Single-node ES caps at ~31g heap. For higher RAM saturation, run multiple instances in separate namespaces (see below).

---

## Auto-Tune Script

```bash
./scripts/auto-tune.sh > .env
```

Detects VM RAM and CPU and writes recommended `.env` values.

---

## Multi-Namespace Scaling (Large Servers)

Single-node ES caps at ~31 GiB heap. On a large server (256 CPU, 512 GiB+ RAM), run multiple ES instances in separate namespaces — each in its own StatefulSet with its own NodePort.

Deploy a second instance:
```bash
NAMESPACE=es-stress-2 ES_NODEPORT=30921 ./setup.sh
python3 scripts/fire-load.py --host http://localhost:30921 --target-ram 78 --duration 30 --threads 8 --yes
```

> Note: `ES_NODEPORT` parameterization is planned — track progress in the project issues.

---

## Multi-Node Cluster (Alternative)

Instead of multiple namespaces, you can scale the StatefulSet to multiple replicas. Edit `manifests/elasticsearch.yaml`:

1. Change `replicas: 1` to your desired node count.
2. Remove `discovery.type: single-node`.
3. Add discovery settings:

```yaml
- name: discovery.seed_hosts
  value: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
- name: cluster.initial_master_nodes
  value: "elasticsearch-0,elasticsearch-1,elasticsearch-2"
```

| Replicas × Heap | Total RAM use |
|---|---|
| 3 × 31g | ~186 GiB |
| 6 × 31g | ~372 GiB |
| 16 × 31g | ~992 GiB |

---

## Troubleshooting

### RAM not releasing after test
`fire-load.py` calls `./stop.sh` automatically on finish. If RAM is still high, run it manually:
```bash
./stop.sh
```
This scales ES to 0 and kills any CRI-O orphan JVM processes.

### Pod stuck in Error after force-delete (stale lock files)
`./setup.sh` now deletes PVCs and wipes all resources before every deploy, so stale `node.lock` / `write.lock` files are gone before ES starts. If you still see this, run `./setup.sh` again — it will wipe and redeploy clean.

### OOMKilled
Reduce `ES_HEAP_SIZE` in `.env` by 25% and re-run `./setup.sh`.

### Cannot connect to ES after setup
```bash
kubectl get pods -n es-stress
kubectl logs -n es-stress elasticsearch-0
```
ES takes 30–60 seconds to initialize after the pod is Ready. If the NodePort isn't reachable, check `kubectl get svc -n es-stress`.
