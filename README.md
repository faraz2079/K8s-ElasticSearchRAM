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

## Sizing

| VM RAM    | ES_HEAP_SIZE | Expected steady-state RAM use |
|-----------|--------------|-------------------------------|
| 30 GiB    | 16g          | ~24 GiB (80%)                 |
| 64 GiB    | 31g          | ~50 GiB (78%)                 |
| 256 GiB   | 31g (per node, 4 nodes) | ~200 GiB (78%) |

Rule: JVM heap ≤ 50% of node RAM, never exceed 31 GiB per node.

