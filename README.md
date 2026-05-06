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
- git clone <this-repo>
- cd elasticsearch-stress-test
- cp .env.example .env
- ./setup.sh
- ./run.sh

## Configuration & Sizing

This setup is portable across any VM size. **All sizing is controlled by a single file: `.env`.** You do not need to edit YAML manifests, scripts, or worker code — only `.env`.

For most cases, just run the auto-tuner and you're done:

```bash
./scripts/auto-tune.sh > .env
```

For everything else, see the sections below.

---

### How RAM Targeting Works

Elasticsearch consumes RAM in two ways:

1. **JVM heap** — controlled by `ES_HEAP_SIZE`. Used for indexes, queries, aggregations.
2. **OS file cache** — used implicitly by the kernel to cache index files on disk. Elasticsearch is designed to rely on this for fast lookups.

A well-tuned Elasticsearch node uses **~50% of node RAM as heap** and leaves the rest for OS cache. Both fill up under sustained load, so the total RAM consumption settles at **roughly 2× the heap size**.

**Sizing rules** (from official Elasticsearch tuning guidance):
- JVM heap should never exceed **50% of node RAM**
- JVM heap should never exceed **31 GiB** per node (above this, JVM compressed pointers stop working and performance degrades)
- For higher targets, scale to **multiple ES nodes** instead of a bigger heap

---

### The `.env` File — All Knobs You Need

| Variable | Purpose | Tuning rule |
|---|---|---|
| `NAMESPACE` | Kubernetes namespace | Usually leave as `es-stress` |
| `ES_HEAP_SIZE` | JVM heap (`-Xms`, `-Xmx`) | 50% of VM RAM, max `31g` |
| `ES_MEM_REQUEST` | K8s pod memory request (guarantee) | `ES_HEAP_SIZE + 2 GiB` |
| `ES_MEM_LIMIT` | K8s pod memory limit (hard ceiling) | `ES_HEAP_SIZE + 4 GiB` |
| `ES_CPU_REQUEST` | Guaranteed CPU cores | ~25% of VM vCPUs |
| `ES_CPU_LIMIT` | Hard CPU ceiling | ~50% of VM vCPUs |
| `ES_STORAGE` | Disk volume for index data | 4× heap size minimum |
| `LOADER_REPLICAS` | Number of indexing pods | 1 per 4 vCPUs, min 2, max 16 |
| `LOADER_BATCH_SIZE` | Bulk insert size per request | 500–1000 (500 is optimal) |
| `LOADER_DOCS_PER_BATCH` | Docs prepared per loop iteration | 10,000–50,000 |
| `DEFAULT_DURATION` | Default seconds for `./run.sh` | 1800 (30 min) |
| `SAMPLE_INTERVAL` | Metric sampling cadence (seconds) | 5 |

---

### Quick Sizing Cheat Sheet

Pick the closest VM size and copy these values into your `.env`. Expected RAM usage assumes the loader runs for at least 10 minutes.

#### 16 GiB / 8 vCPU
```env
ES_HEAP_SIZE=8g
ES_MEM_REQUEST=10Gi
ES_MEM_LIMIT=12Gi
ES_CPU_REQUEST=2
ES_CPU_LIMIT=4
ES_STORAGE=32Gi
LOADER_REPLICAS=2
```
**Expected RAM use: ~13 GiB (80%)**

#### 30 GiB / 16 vCPU
```env
ES_HEAP_SIZE=16g
ES_MEM_REQUEST=18Gi
ES_MEM_LIMIT=20Gi
ES_CPU_REQUEST=2
ES_CPU_LIMIT=8
ES_STORAGE=50Gi
LOADER_REPLICAS=2
```
**Expected RAM use: ~24 GiB (80%)**

#### 64 GiB / 32 vCPU
```env
ES_HEAP_SIZE=31g
ES_MEM_REQUEST=33Gi
ES_MEM_LIMIT=36Gi
ES_CPU_REQUEST=4
ES_CPU_LIMIT=16
ES_STORAGE=200Gi
LOADER_REPLICAS=4
```
**Expected RAM use: ~50 GiB (78%)**

#### 128 GiB / 64 vCPU (single-node)
```env
ES_HEAP_SIZE=31g
ES_MEM_REQUEST=33Gi
ES_MEM_LIMIT=36Gi
ES_CPU_REQUEST=8
ES_CPU_LIMIT=32
ES_STORAGE=500Gi
LOADER_REPLICAS=8
```
**Expected RAM use: ~62 GiB (48%)** — single-node caps here. For higher RAM use, switch to multi-node (see below).

#### 256 vCPU / 2 TiB (the real big-server scenario)
Single-node maxes out at ~62 GiB RAM. To use the full machine, switch to a multi-node cluster.

```env
ES_HEAP_SIZE=31g
ES_MEM_REQUEST=33Gi
ES_MEM_LIMIT=36Gi
ES_CPU_REQUEST=8
ES_CPU_LIMIT=32
ES_STORAGE=2Ti
LOADER_REPLICAS=32
```

Plus edit the manifest — see [Multi-Node Cluster](#multi-node-cluster-for-very-large-targets) below.

---

### Auto-Tune Script

Skip the cheat sheet entirely — let the script figure it out:

```bash
./scripts/auto-tune.sh
```

This detects your VM's RAM and CPU and prints recommended `.env` values. To apply directly:

```bash
./scripts/auto-tune.sh > .env
```

The script also warns you if your VM is large enough that you should switch to a multi-node setup.

---

### Multi-Node Cluster (for very large targets)

Single-node Elasticsearch caps out at roughly **62 GiB total RAM** (31 GiB heap + 31 GiB OS cache). For higher RAM targets, run multiple ES nodes.

**Edit `manifests/elasticsearch.yaml`:**

1. Change `replicas: 1` to your desired node count (e.g. `3`, `4`, `8`).
2. Remove or comment out the `discovery.type: single-node` env var.
3. Add multi-node discovery settings:

```yaml
        env:
        # ...existing env vars (KEEP these, just remove discovery.type)...
        - name: discovery.seed_hosts
          value: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
        - name: cluster.initial_master_nodes
          value: "elasticsearch-0,elasticsearch-1,elasticsearch-2"
        - name: node.roles
          value: "master,data,ingest"
```

(Adjust the seed_hosts list to match your replica count.)

Each replica becomes a separate ES node communicating via the headless service. Total RAM use becomes approximately `replicas × (heap × 2)`.

| Replicas × Heap | Total RAM use |
|---|---|
| 3 × 31g | ~186 GiB |
| 6 × 31g | ~372 GiB |
| 16 × 31g | ~992 GiB |
| 32 × 31g | ~1.9 TiB |

After editing the manifest, re-run `./setup.sh` to apply.

---

### Tuning Knobs Beyond `.env`

These optional adjustments push RAM usage harder:

#### Force caches to stay warm
Edit `manifests/elasticsearch.yaml`, add to the env block:

```yaml
        - name: indices.queries.cache.size
          value: "20%"
        - name: indices.fielddata.cache.size
          value: "40%"
```

This tells Elasticsearch to reserve more heap for query and field data caches, which fill up under sustained workload.

#### Push loader pressure
Increase indexing rate so RAM fills faster:

```env
LOADER_REPLICAS=8
LOADER_DOCS_PER_BATCH=50000
```

#### Larger storage for longer runs
For multi-hour stress runs, the default storage volume fills up. Bump `ES_STORAGE`:

```env
ES_STORAGE=200Gi    # or 500Gi, 1Ti
```

---

### Procedure for a New Machine

```bash
# 1. Clone and configure
git clone https://github.com/YOUR_USERNAME/elasticsearch-stress-test.git
cd elasticsearch-stress-test

# 2. Auto-generate .env for this VM
./scripts/auto-tune.sh > .env

# 3. (Required) set host sysctl for Elasticsearch
echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elasticsearch.conf
sudo sysctl -p /etc/sysctl.d/99-elasticsearch.conf

# 4. Deploy
./setup.sh

# 5. Run
./run.sh                 # default duration
./run.sh 600             # 10 min run
./run.sh 3600            # 1 hour run
```

The same repo runs on any VM — only the `.env` values differ.

---

### What If RAM Doesn't Fill Up?

If after 10–15 minutes RAM hasn't reached your target, check in this order:

1. **`kubectl top pods -n es-stress`** — is Elasticsearch using close to its `ES_HEAP_SIZE`? If not, the loader isn't pushing enough data. Increase `LOADER_REPLICAS` or `LOADER_DOCS_PER_BATCH`.
2. **`kubectl logs -n es-stress -l app=es-loader`** — is the loader actually indexing? If you see errors, fix them first.
3. **`kubectl exec -n es-stress statefulset/elasticsearch -- curl -s localhost:9200/_cat/indices?v`** — should show indices growing in size and document count.
4. **OS file cache** isn't reflected by `kubectl top`. Check `free -h` on the host — `buff/cache` should grow over time. That's the second half of your "RAM use."

---

### Safety: Watch for OOMKills

A heap that's too aggressive will get the pod killed. Warning signs:

- Pod status: `OOMKilled` or `CrashLoopBackOff`
- `kubectl describe pod -n es-stress elasticsearch-0` shows `Last State: Terminated`, `Reason: OOMKilled`

If this happens, reduce `ES_HEAP_SIZE` in `.env` by 25% and re-apply:

```bash
./setup.sh   # re-renders manifests with new values
kubectl rollout restart statefulset/elasticsearch -n es-stress
```
