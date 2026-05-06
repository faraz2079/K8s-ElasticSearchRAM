#!/bin/bash
# Generates a human-readable summary from a run folder's summary.csv
set -u

RUN_DIR=${1:-$(ls -td ~/work/elasticsearch-stress-test/runs/run-* 2>/dev/null | head -1)}

if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  echo "Usage: $0 [run-folder]"
  echo "(if no folder given, uses the most recent run)"
  exit 1
fi

CSV="$RUN_DIR/summary.csv"
[ ! -f "$CSV" ] && { echo "summary.csv not found in $RUN_DIR"; exit 1; }

# Detect VM RAM (in MiB) for percentage calculations
VM_RAM_MIB=$(free -m | awk '/^Mem:/ {print $2}')

awk -F, -v vmram="$VM_RAM_MIB" '
NR == 1 { next }  # skip header
NR == 2 {
  baseline_node_mem = $4 + 0
}
{
  rows++
  # Sums for averages
  node_cpu_sum += $3+0;  node_mem_sum += $4+0
  es_cpu_sum   += $5+0;  es_mem_sum   += $6+0
  ldr_cpu_sum  += $7+0;  ldr_mem_sum  += $8+0

  # Peaks
  if ($3+0 > node_cpu_peak) node_cpu_peak = $3+0
  if ($4+0 > node_mem_peak) node_mem_peak = $4+0
  if ($5+0 > es_cpu_peak)   es_cpu_peak   = $5+0
  if ($6+0 > es_mem_peak)   es_mem_peak   = $6+0
  if ($7+0 > ldr_cpu_peak)  ldr_cpu_peak  = $7+0
  if ($8+0 > ldr_mem_peak)  ldr_mem_peak  = $8+0

  # Last seen values
  last_elapsed = $2+0
  last_docs    = $9+0
}
END {
  if (rows == 0) { print "No data rows."; exit }

  printf "\n========== RUN SUMMARY ==========\n"
  printf "Run folder:  %s\n", "'"$RUN_DIR"'"
  printf "Duration:    %ds (~%.1f min)\n", last_elapsed, last_elapsed/60
  printf "Samples:     %d\n", rows
  printf "VM total:    %d MiB\n\n", vmram

  printf "NODE-LEVEL (whole VM)\n"
  printf "  Baseline RAM: %6d MiB (%.1f%%)\n", baseline_node_mem, baseline_node_mem*100/vmram
  printf "  Peak RAM:     %6d MiB (%.1f%%)  %s\n", node_mem_peak, node_mem_peak*100/vmram, \
         (node_mem_peak*100/vmram >= 80 ? "  TARGET REACHED" : "")
  printf "  Avg RAM:      %6d MiB (%.1f%%)\n", node_mem_sum/rows, (node_mem_sum/rows)*100/vmram
  printf "  Peak CPU:     %6d m\n", node_cpu_peak
  printf "  Avg CPU:      %6d m\n\n", node_cpu_sum/rows

  printf "ELASTICSEARCH POD\n"
  printf "  Peak RAM:     %6d MiB\n", es_mem_peak
  printf "  Avg RAM:      %6d MiB\n", es_mem_sum/rows
  printf "  Peak CPU:     %6d m\n", es_cpu_peak
  printf "  Avg CPU:      %6d m\n\n", es_cpu_sum/rows

  printf "LOADER PODS (combined)\n"
  printf "  Peak CPU:     %6d m\n", ldr_cpu_peak
  printf "  Avg CPU:      %6d m\n", ldr_cpu_sum/rows
  printf "  Peak RAM:     %6d MiB\n", ldr_mem_peak
  printf "  Avg RAM:      %6d MiB\n\n", ldr_mem_sum/rows

  printf "WORKLOAD\n"
  printf "  Total docs:   %d\n", last_docs
  if (last_elapsed > 0)
    printf "  Index rate:   %.0f docs/sec\n", last_docs/last_elapsed
  printf "==================================\n"
}
' "$CSV"
