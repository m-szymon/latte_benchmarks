#!/bin/bash
set -euo pipefail
#
# run-ycsb-benchmark.sh — Runs YCSB measured pass inside scylladb/ycsb:1.3.0 container.
# Schema + load is handled separately by the orchestrator.
#

ALT_ENDPOINT="${ALT_ENDPOINT:?ALT_ENDPOINT must be set}"
TABLE="${TABLE:-latte_performance}"
ROW_COUNT="${ROW_COUNT:-100000}"
YCSB_THREADS="${YCSB_THREADS:-64}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
OUTDIR="${OUTDIR:-/output}"
RATE="${RATE:-}"
RUN_DURATION_SEC="${RUN_DURATION_SEC:-30}"
WARMUP_SEC="${WARMUP_SEC:-0}"
READ_PROPORTION="${READ_PROPORTION:-0.5}"
UPDATE_PROPORTION="${UPDATE_PROPORTION:-0.5}"
YCSB_JAVA_OPTS="${YCSB_JAVA_OPTS:-}"

# Pass JVM options if provided (e.g. -Xmx8g -XX:+UseG1GC)
if [ -n "$YCSB_JAVA_OPTS" ]; then
  export JAVA_OPTS="$YCSB_JAVA_OPTS"
fi

mkdir -p "$OUTDIR"

COMMON_ARGS=(
  -P "${YCSB_HOME:-/usr/local/share/scylla-ycsb}/workloads/workloada"
  -threads "$YCSB_THREADS"
  -p "table=$TABLE"
  -p "recordcount=$ROW_COUNT"
  -p "requestdistribution=uniform"
  -p "readproportion=$READ_PROPORTION"
  -p "updateproportion=$UPDATE_PROPORTION"
  -p "insertproportion=0"
  -p "scanproportion=0"
  -p "readmodifywriteproportion=0"
  -p "readallfields=true"
  -p "writeallfields=false"
  -p "fieldcount=$FIELDCOUNT"
  -p "fieldlength=$FIELDLENGTH"
  -p "fieldlengthdistribution=constant"
  -p "dynamodb.primaryKey=pk"
  -p "dynamodb.primaryKeyType=HASH"
  -p "dynamodb.endpoint=$ALT_ENDPOINT"
  -p "dynamodb.consistentReads=false"
  -p "dynamodb.awsAccessKey=dummy"
  -p "dynamodb.awsSecretKey=dummy"
  -p "dynamodb.region=us-east-1"
  -p "measurement.interval=both"
)

if [ -n "$RATE" ]; then
  COMMON_ARGS+=(-target "$RATE")
fi

COMMON_ARGS+=(-p "maxexecutiontime=$RUN_DURATION_SEC")
COMMON_ARGS+=(-p "operationcount=999999999")

echo "=== YCSB Benchmark ==="
echo "Endpoint: $ALT_ENDPOINT"
echo "Table: $TABLE | Rows: $ROW_COUNT | Threads: $YCSB_THREADS"
echo "Duration: ${RUN_DURATION_SEC}s | Warmup: ${WARMUP_SEC}s | Rate: ${RATE:-unlimited}"
echo

# Warmup pass (discard output)
if [ "$WARMUP_SEC" -gt 0 ]; then
  echo "[1/2] Warmup pass (${WARMUP_SEC}s, discarded)..."
  ycsb.sh run dynamodb \
    "${COMMON_ARGS[@]}" \
    -p "maxexecutiontime=$WARMUP_SEC" \
    > /dev/null 2>&1 || true
  echo "Warmup complete."
fi

# Measured run
echo "[2/2] Measured run (${RUN_DURATION_SEC}s)..."
export LC_ALL=C
export TIMEFORMAT="TIMEFORMAT %R %U %S"
{ time ycsb.sh run dynamodb "${COMMON_ARGS[@]}"; } \
  > "$OUTDIR/ycsb_1.log" 2>&1

echo "Done. Results in: $OUTDIR/ycsb_1.log"
