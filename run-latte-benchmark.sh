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
REQUEST_COMPRESSION="${REQUEST_COMPRESSION:-}"

mkdir -p "$OUTDIR"

RATE_ARG=""
if [ -n "$RATE" ]; then
  RATE_ARG="-r $RATE"
fi

WARMUP_ARG=""
if [ "$WARMUP_SEC" -gt 0 ]; then
  WARMUP_ARG="--warmup ${WARMUP_SEC}s"
fi

LB_ARG=""
if [ -n "$LB_POLICY" ]; then
  if [ "$LB_POLICY" = "affinity-key-routing" ]; then
    LB_ARG="--key-route-affinity rmw --key-route-affinity-table ${TABLE}=pk"
  elif [ "$LB_POLICY" = "round-robin" ]; then
    LB_ARG=""
  fi
fi

COMPRESSION_ARG=""
if [ -n "$REQUEST_COMPRESSION" ]; then
  COMPRESSION_ARG="--request-compression $REQUEST_COMPRESSION"
fi

echo "=== Latte Alternator Benchmark ==="
echo "Endpoint: $ALT_ENDPOINT"
echo "Table: $TABLE | Rows: $ROW_COUNT | Threads: $THREADS | Concurrency: $CONCURRENCY"
echo "In-flight: $((THREADS * CONCURRENCY))"
echo "Duration: ${RUN_DURATION_SEC}s | Warmup: ${WARMUP_SEC}s | Rate: ${RATE:-unlimited}"
echo

export LC_ALL=C
export TIMEFORMAT="TIMEFORMAT %R %U %S"

echo "[1/1] Running Latte benchmark"
# shellcheck disable=SC2086
{ time "$LATTE_BINARY" run "$LATTE_WORKLOAD" "$ALT_ENDPOINT" \
  -t "$THREADS" -p "$CONCURRENCY" -d "${RUN_DURATION_SEC}s" $RATE_ARG $WARMUP_ARG $LB_ARG $COMPRESSION_ARG \
  -P "table=\"$TABLE\"" \
  -P "row_count=$ROW_COUNT" \
  -P "fieldcount=$FIELDCOUNT" \
  -P "fieldlength=$FIELDLENGTH" \
  -P 'requestdistribution="uniform"' \
  -P "alternator.consistentReads=false" \
  -f "get:$READ_PROPORTION" -f "update:$UPDATE_PROPORTION" \
  -q -o "$OUTDIR/latte_1.json" --generate-report; } \
  > "$OUTDIR/latte_1.log" 2>&1

echo "Done. Results in: $OUTDIR/"
