#!/bin/bash
set -euo pipefail

ALT_ENDPOINT="${ALT_ENDPOINT:-http://172.17.0.2:8000}"
TABLE="${TABLE:-latte_performance}"
CONCURRENCY="${CONCURRENCY:-1}"
ROW_COUNT="${ROW_COUNT:-100000}"
REQUEST_COUNT="${REQUEST_COUNT:-500000}"
THREADS="${THREADS:-8}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
OUTDIR="${OUTDIR:-output}"
LATTE_WORKLOAD="${LATTE_WORKLOAD:-performance.rn}"
RATE="${RATE:-}"
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

echo "[1/3] Schema + load for Latte Alternator"
latte-alternator schema "$LATTE_WORKLOAD" "$ALT_ENDPOINT" -P "table=\"$TABLE\""
latte-alternator load "$LATTE_WORKLOAD" "$ALT_ENDPOINT" \
  -t "$THREADS" -c 12 --concurrency 12 \
  -P "table=\"$TABLE\"" \
  -P "row_count=$ROW_COUNT" \
  -P "fieldcount=$FIELDCOUNT" \
  -P "fieldlength=$FIELDLENGTH" \
  -P 'requestdistribution="uniform"' \
  > "$OUTDIR/latte_load.log" 2>&1

RATE_ARG=""
if [ -n "$RATE" ]; then
  RATE_ARG="-r $RATE"
fi

export LC_ALL=C
export TIMEFORMAT="TIMEFORMAT %R %U %S"

echo "[2/3] Running Latte benchmark"
{ time latte-alternator run "$LATTE_WORKLOAD" "$ALT_ENDPOINT" \
  -t "$THREADS" -p "$CONCURRENCY" -c 12 -d "$REQUEST_COUNT" $RATE_ARG \
  -P "table=\"$TABLE\"" \
  -P "row_count=$ROW_COUNT" \
  -P "fieldcount=$FIELDCOUNT" \
  -P "fieldlength=$FIELDLENGTH" \
  -P 'requestdistribution="uniform"' \
  -P "alternator.consistentReads=false" \
  -f "get:$READ_PROPORTION" -f "update:$UPDATE_PROPORTION" \
  -q -o "$OUTDIR/latte_1.json" --generate-report; } \
  > "$OUTDIR/latte_1.log" 2>&1

python3 /usr/local/bin/analyze_latte_results.py "$OUTDIR"

echo "[3/3] Done. Detailed results in: $OUTDIR"
