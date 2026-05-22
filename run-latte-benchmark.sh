#!/bin/bash
set -euo pipefail
#
# run-latte-benchmark.sh — Runs Latte alternator measured pass.
# Schema + load is handled separately by the orchestrator.
#

ALT_ENDPOINT="${ALT_ENDPOINT:?ALT_ENDPOINT must be set}"
TABLE="${TABLE:-latte_performance}"
ROW_COUNT="${ROW_COUNT:-100000}"
THREADS="${THREADS:-8}"
CONCURRENCY="${CONCURRENCY:-8}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
OUTDIR="${OUTDIR:-/output}"
RATE="${RATE:-}"
RUN_DURATION_SEC="${RUN_DURATION_SEC:-30}"
WARMUP_SEC="${WARMUP_SEC:-0}"
READ_PROPORTION="${READ_PROPORTION:-0.5}"
UPDATE_PROPORTION="${UPDATE_PROPORTION:-0.5}"
LATTE_WORKLOAD="${LATTE_WORKLOAD:-performance.rn}"
LATTE_BINARY="${LATTE_BINARY:-latte-alternator}"
LB_POLICY="${LB_POLICY:-}"
KEY_ROUTE_AFFINITY_MODE="${KEY_ROUTE_AFFINITY_MODE:-}"
REQUEST_COMPRESSION="${REQUEST_COMPRESSION:-}"
REQUEST_DISTRIBUTION="${REQUEST_DISTRIBUTION:-uniform}"
HOT_ITEMS="${HOT_ITEMS:-}"
COLD_PARTITIONS="${COLD_PARTITIONS:-}"
HOT_TRAFFIC_RATIO="${HOT_TRAFFIC_RATIO:-}"
HOT_PARTITIONS="${HOT_PARTITIONS:-}"
HOT_ITEMS_PER_PARTITION="${HOT_ITEMS_PER_PARTITION:-}"

mkdir -p "$OUTDIR"

RATE_ARG=""
if [ -n "$RATE" ]; then
  RATE_ARG="-r $RATE"
fi

WARMUP_ARG=""
if [ "$WARMUP_SEC" -gt 0 ]; then
  WARMUP_ARG="--warmup ${WARMUP_SEC}s"
fi

resolve_affinity_mode() {
  if [ -n "$KEY_ROUTE_AFFINITY_MODE" ]; then
    echo "$KEY_ROUTE_AFFINITY_MODE"
    return
  fi

  python3 - <<'PY'
import os
read_p = float(os.environ.get("READ_PROPORTION", "0.5"))
update_p = float(os.environ.get("UPDATE_PROPORTION", "0.5"))
if update_p <= 0.0:
    print("any-read")
elif read_p <= 0.0:
    print("any-write")
else:
    print("rmw")
PY
}

LB_ARG=""
if [ -n "$LB_POLICY" ]; then
  if [ "$LB_POLICY" = "affinity-key-routing" ]; then
    affinity_mode=$(resolve_affinity_mode)
    LB_ARG="--key-route-affinity ${affinity_mode} --key-route-affinity-table ${TABLE}=pk"
  elif [ "$LB_POLICY" = "round-robin" ]; then
    LB_ARG=""
  fi
fi

COMPRESSION_ARG=""
if [ -n "$REQUEST_COMPRESSION" ]; then
  COMPRESSION_ARG="--request-compression $REQUEST_COMPRESSION"
fi

EXTRA_PARAMS_ARGS=""
if [ -n "$COLD_PARTITIONS" ]; then
  EXTRA_PARAMS_ARGS="$EXTRA_PARAMS_ARGS -P cold_partitions=$COLD_PARTITIONS"
fi
if [ -n "$HOT_TRAFFIC_RATIO" ]; then
  EXTRA_PARAMS_ARGS="$EXTRA_PARAMS_ARGS -P hot_traffic_ratio=$HOT_TRAFFIC_RATIO"
fi
if [ -n "$HOT_PARTITIONS" ]; then
  EXTRA_PARAMS_ARGS="$EXTRA_PARAMS_ARGS -P hot_partitions=$HOT_PARTITIONS"
fi
if [ -n "$HOT_ITEMS_PER_PARTITION" ]; then
  EXTRA_PARAMS_ARGS="$EXTRA_PARAMS_ARGS -P hot_items_per_partition=$HOT_ITEMS_PER_PARTITION"
fi

echo "=== Latte Alternator Benchmark ==="
echo "Endpoint: $ALT_ENDPOINT"
echo "Table: $TABLE | Rows: $ROW_COUNT | Threads: $THREADS | Concurrency: $CONCURRENCY"
echo "In-flight: $((THREADS * CONCURRENCY))"
echo "Duration: ${RUN_DURATION_SEC}s | Warmup: ${WARMUP_SEC}s | Rate: ${RATE:-unlimited}"
if [ -n "$LB_ARG" ]; then
  echo "Key route affinity: $(resolve_affinity_mode)"
fi
if [ -n "$HOT_TRAFFIC_RATIO" ]; then
  echo "Hot traffic ratio: $HOT_TRAFFIC_RATIO | Hot partitions: ${HOT_PARTITIONS:-n/a} | Items/partition: ${HOT_ITEMS_PER_PARTITION:-n/a}"
  echo "Hot items: ${HOT_ITEMS:-n/a} | Cold partitions: ${COLD_PARTITIONS:-n/a} | Read/Update: $READ_PROPORTION/$UPDATE_PROPORTION"
  cat > "$OUTDIR/workload_params.txt" <<EOF
workload=$LATTE_WORKLOAD
table=$TABLE
hot_traffic_ratio=$HOT_TRAFFIC_RATIO
hot_partitions=$HOT_PARTITIONS
hot_items_per_partition=$HOT_ITEMS_PER_PARTITION
hot_items=$HOT_ITEMS
cold_partitions=$COLD_PARTITIONS
read_proportion=$READ_PROPORTION
update_proportion=$UPDATE_PROPORTION
lb_policy=${LB_POLICY:-default}
affinity_mode=$(resolve_affinity_mode)
EOF
fi
echo

export LC_ALL=C
export TIMEFORMAT="TIMEFORMAT %R %U %S"

echo "[1/1] Running Latte benchmark"
# shellcheck disable=SC2086
{ time "$LATTE_BINARY" run "$LATTE_WORKLOAD" $ALT_ENDPOINT \
  -t "$THREADS" -p "$CONCURRENCY" -d "${RUN_DURATION_SEC}s" $RATE_ARG $WARMUP_ARG $LB_ARG $COMPRESSION_ARG \
  -P "table=\"$TABLE\"" \
  -P "row_count=$ROW_COUNT" \
  -P "fieldcount=$FIELDCOUNT" \
  -P "fieldlength=$FIELDLENGTH" \
  -P "requestdistribution=\"${REQUEST_DISTRIBUTION}\"" \
  -P "alternator.consistentReads=false" \
  $EXTRA_PARAMS_ARGS \
  -f "get:$READ_PROPORTION" -f "update:$UPDATE_PROPORTION" \
  -q -o "$OUTDIR/latte_1.json" --generate-report; } \
  > "$OUTDIR/latte_1.log" 2>&1

echo "Done. Results in: $OUTDIR/"
