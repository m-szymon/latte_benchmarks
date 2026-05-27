#!/usr/bin/env bash
#
# Shared latency-phase benchmark configuration and validation.
# Sourced by local-benchmark.sh and aws-benchmark.sh after benchmark-hot-common.sh.
#
# Requires orchestrator to define: parse_scylla_max_node_cpu_avg(out_dir)
#

: "${LATENCY_MIN_SKEW_IMBALANCE:=2.5}"
: "${LATENCY_MIN_HOT_NODE_CPU_AVG:=95}"
: "${LATENCY_MAX_LB_NODE_CPU_AVG:=70}"

is_latency_phase() {
    [[ "$1" == latency* ]]
}

latency_benchmark_is_local() {
    [[ "${RESULTS_DIR:-}" == *benchmark-results-local* ]]
}

apply_latency_phase_defaults() {
    if latency_benchmark_is_local; then
        : "${LATENCY_RATE:=800}"
        : "${LATENCY_INFLIGHT:=32 48}"
    else
        : "${LATENCY_RATE:=30000}"
        : "${LATENCY_INFLIGHT:=128 256}"
    fi
    : "${LATENCY_THREADS_HINT:=16}"

    RATE="$LATENCY_RATE"
    INFLIGHT_LIST="$LATENCY_INFLIGHT"
    LATTE_THREADS_HINT="$LATENCY_THREADS_HINT"
}

# Log per-node averages when AWS scyllaN_cpu.log files exist.
_latency_log_node_cpu_avgs() {
    local out_dir="$1"
    local parts=() n avg log
    if ! declare -f parse_cpu_pct &>/dev/null; then
        return 0
    fi
    for ((n=1; n<=SCYLLA_NODES; n++)); do
        log="$out_dir/scylla${n}_cpu.log"
        if [[ -f "$log" ]]; then
            avg=$(parse_cpu_pct "$log")
            parts+=("scylla${n}=${avg}%")
        fi
    done
    if [[ ${#parts[@]} -gt 0 ]]; then
        log "  Node CPU avgs: ${parts[*]}"
    fi
}

validate_latency_run() {
    local tool="$1"
    local out_dir="$2"

    if ! declare -f parse_scylla_max_node_cpu_avg &>/dev/null; then
        log "WARN: parse_scylla_max_node_cpu_avg not defined — skipping latency validation"
        return 0
    fi

    local max_cpu imbalance="0"
    max_cpu=$(parse_scylla_max_node_cpu_avg "$out_dir")

    local -a prom_logs=()
    for f in "$out_dir"/scylla*_prometheus.log; do
        [[ -f "$f" ]] && prom_logs+=("$f")
    done
    [[ -f "$out_dir/scylla_prometheus.log" ]] && prom_logs+=("$out_dir/scylla_prometheus.log")
    if [[ ${#prom_logs[@]} -gt 0 ]]; then
        imbalance=$(python3 "$BENCHMARKS_DIR/analyze_scylla_metrics.py" "${prom_logs[@]}" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ops_imbalance_ratio','0'))" 2>/dev/null || echo "0")
    fi

    _latency_log_node_cpu_avgs "$out_dir"
    log "  Latency check: tool=$tool max_node_cpu_avg=${max_cpu}% ops_imbalance=$imbalance"

    case "$tool" in
        latte)
            if awk -v i="$imbalance" -v t="$LATENCY_MIN_SKEW_IMBALANCE" 'BEGIN { exit !(i < t) }'; then
                log "WARN: latency $tool ops_imbalance_ratio $imbalance < $LATENCY_MIN_SKEW_IMBALANCE (expected skew)"
            fi
            if awk -v c="$max_cpu" -v t="$LATENCY_MIN_HOT_NODE_CPU_AVG" 'BEGIN { exit !(c < t) }'; then
                log "WARN: latency $tool scylla_max_node_cpu_avg_pct ${max_cpu}% < ${LATENCY_MIN_HOT_NODE_CPU_AVG}% (hot node not saturated)"
            fi
            ;;
        latte-new-rr|latte-new-affinity)
            if awk -v i="$imbalance" -v t="1.15" 'BEGIN { exit !(i > t) }'; then
                log "WARN: latency $tool ops_imbalance_ratio $imbalance > 1.15 (expected balanced load)"
            fi
            if awk -v c="$max_cpu" -v t="$LATENCY_MAX_LB_NODE_CPU_AVG" 'BEGIN { exit !(c > t) }'; then
                log "WARN: latency $tool scylla_max_node_cpu_avg_pct ${max_cpu}% > ${LATENCY_MAX_LB_NODE_CPU_AVG}% (soft — expected at high rate)"
            fi
            ;;
    esac
    return 0
}
