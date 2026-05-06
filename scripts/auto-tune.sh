#!/bin/bash
# Auto-detects VM specs and prints recommended .env values
set -u

VM_RAM_GIB=$(free -g | awk '/^Mem:/ {print $2}')
VM_CPU=$(nproc)

# JVM heap = 50% of RAM, capped at 31g
HEAP_GIB=$(( VM_RAM_GIB / 2 ))
[ $HEAP_GIB -gt 31 ] && HEAP_GIB=31

MEM_REQUEST=$(( HEAP_GIB + 2 ))
MEM_LIMIT=$(( HEAP_GIB + 4 ))

CPU_REQUEST=$(( VM_CPU / 4 ))
[ $CPU_REQUEST -lt 1 ] && CPU_REQUEST=1
CPU_LIMIT=$(( VM_CPU / 2 ))
[ $CPU_LIMIT -lt 2 ] && CPU_LIMIT=2

# Loaders — 1 per 4 vCPUs, min 2, max 16
LOADERS=$(( VM_CPU / 4 ))
[ $LOADERS -lt 2 ] && LOADERS=2
[ $LOADERS -gt 16 ] && LOADERS=16

# Storage — generous, scales with heap
STORAGE_GIB=$(( HEAP_GIB * 4 ))

echo "==============================================="
echo "  Detected VM: ${VM_RAM_GIB} GiB RAM, ${VM_CPU} vCPU"
echo "==============================================="
echo
echo "Recommended .env values:"
echo
cat <<EOF
NAMESPACE=es-stress
ES_HEAP_SIZE=${HEAP_GIB}g
ES_MEM_REQUEST=${MEM_REQUEST}Gi
ES_MEM_LIMIT=${MEM_LIMIT}Gi
ES_CPU_REQUEST=${CPU_REQUEST}
ES_CPU_LIMIT=${CPU_LIMIT}
ES_STORAGE=${STORAGE_GIB}Gi
LOADER_REPLICAS=${LOADERS}
LOADER_BATCH_SIZE=500
LOADER_DOCS_PER_BATCH=10000
DEFAULT_DURATION=1800
SAMPLE_INTERVAL=5
EOF
echo
echo "Expected steady-state RAM usage: ~$((HEAP_GIB * 2)) GiB ($((HEAP_GIB * 200 / VM_RAM_GIB))%)"
echo

if [ $VM_RAM_GIB -gt 64 ]; then
  echo "NOTE: Your VM has >64 GiB. Single-node ES caps at 31g heap."
  echo "      To use more RAM, edit manifests/elasticsearch.yaml:"
  echo "        - Change 'replicas: 1' to a higher number"
  echo "        - Remove 'discovery.type: single-node'"
  echo "        - Add multi-node discovery settings (see README)"
fi
