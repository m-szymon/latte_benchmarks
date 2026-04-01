#!/bin/bash
set -euo pipefail

ALT_ENDPOINT="${ALT_ENDPOINT:-http://172.17.0.2:8000}"
TABLE="${TABLE:-latte_performance}"
ROW_COUNT="${ROW_COUNT:-100000}"
REQUEST_COUNT="${REQUEST_COUNT:-500000}"
# YCSB uses less CPU per thread
YCSB_THREADS="${YCSB_THREADS:-24}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
OUTDIR="${OUTDIR:-output}"
RATE="${RATE:-}"
LATTE_WORKLOAD="${LATTE_WORKLOAD:-performance.rn}"
READ_PROPORTION="${READ_PROPORTION:-0.5}"
UPDATE_PROPORTION="${UPDATE_PROPORTION:-0.5}"

mkdir -p "$OUTDIR"

if ! awk -v read="$READ_PROPORTION" -v update="$UPDATE_PROPORTION" 'BEGIN {
  if (read !~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/) exit 1;
  if (update !~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/) exit 1;
  if (read < 0 || read > 1 || update < 0 || update > 1) exit 1;
  sum = read + update;
  if (sum < 0.999999 || sum > 1.000001) exit 1;
}'; then
  echo "ERROR: READ_PROPORTION and UPDATE_PROPORTION must be numeric in [0,1] and sum to 1.0"
  echo "Current values: READ_PROPORTION=$READ_PROPORTION UPDATE_PROPORTION=$UPDATE_PROPORTION"
  exit 1
fi

echo "Checking endpoint availability..."
if ! curl -fsS -m 3 "$ALT_ENDPOINT" >/dev/null 2>&1; then
  echo "ERROR: Alternator endpoint is not reachable: $ALT_ENDPOINT"
  exit 1
fi

echo "[1/3] Schema + load using Latte"
latte-alternator schema "$LATTE_WORKLOAD" "$ALT_ENDPOINT" -P "table=\"$TABLE\""
latte-alternator load "$LATTE_WORKLOAD" "$ALT_ENDPOINT" \
  -t "$YCSB_THREADS" -c 12 --concurrency 12 \
  -P "table=\"$TABLE\"" \
  -P "row_count=$ROW_COUNT" \
  -P "fieldcount=$FIELDCOUNT" \
  -P "fieldlength=$FIELDLENGTH" \
  -P 'requestdistribution="uniform"' \
  > "$OUTDIR/latte_load.log" 2>&1

RATE_ARG=""
if [ -n "$RATE" ]; then
  RATE_ARG="-target $RATE"
fi

export LC_ALL=C
export TIMEFORMAT="TIMEFORMAT %R %U %S"

echo "[2/3] Running YCSB benchmark"
{ time python2 bin/ycsb run dynamodb \
  -P workloads/workloada \
  -P dynamodb.properties \
  -threads "$YCSB_THREADS" \
  $RATE_ARG \
  -p "table=$TABLE" \
  -p "recordcount=$ROW_COUNT" \
  -p "operationcount=$REQUEST_COUNT" \
  -p "requestdistribution=uniform" \
  -p "readproportion=$READ_PROPORTION" \
  -p "updateproportion=$UPDATE_PROPORTION" \
  -p "insertproportion=0" \
  -p "scanproportion=0" \
  -p "readmodifywriteproportion=0" \
  -p "readallfields=true" \
  -p "writeallfields=false" \
  -p "fieldcount=$FIELDCOUNT" \
  -p "fieldlength=$FIELDLENGTH" \
  -p "fieldlengthdistribution=constant" \
  -p "dynamodb.primaryKey=pk" \
  -p "dynamodb.primaryKeyType=HASH" \
  -p "dynamodb.endpoint=$ALT_ENDPOINT" \
  -p "dynamodb.consistentReads=false"; } \
  > "$OUTDIR/ycsb_1.log" 2>&1

python3 /usr/local/bin/analyze_ycsb_results.py "$OUTDIR"

echo "[3/3] Done. Detailed results in: $OUTDIR"
