#!/usr/bin/env bash
#
# local-benchmark.sh — Verification benchmark: Latte drivers on Alternator (Local Docker).
#
# Usage:
#   ./local-benchmark.sh build           # Local: docker build latte
#   ./local-benchmark.sh provision       # Local: Start Scylla container
#   ./local-benchmark.sh run smoke       # Sanity check (10s, 2 reps, rate 500) + hot copy
#   ./local-benchmark.sh run latency     # Overload vs balanced latency (30s, 2 reps) + hot copy
#   ./local-benchmark.sh run throughput  # Saturated comparison (30s base + 120s hot, 2 reps) + hot copy
#   ./local-benchmark.sh teardown        # Stop and remove containers
#   ./local-benchmark.sh report          # Aggregate all summary.csv tables
#
set -euo pipefail

###############################################################################
# Configuration
###############################################################################

# Docker
NETWORK_NAME="${NETWORK_NAME:-latte-net}"
SCYLLA_CONTAINER_PREFIX="${SCYLLA_CONTAINER_PREFIX:-scylla-node}"
LOADER_CONTAINER="${LOADER_CONTAINER:-latte-loader}"

# Scylla
SCYLLA_NODES="${SCYLLA_NODES:-3}"
SCYLLA_CPUS="${SCYLLA_CPUS:-2}"
SCYLLA_IMAGE="${SCYLLA_IMAGE:-scylladb/scylla-nightly:2026.1.0-dev-0.20251003.20aeed160740-x86_64}"
ALTERNATOR_WRITE_ISOLATION="${ALTERNATOR_WRITE_ISOLATION:-always_use_lwt}"

# Workload parameters
TABLE="${TABLE:-latte_performance}"
HOT_TABLE="${HOT_TABLE:-latte_hot_partition}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
READ_PROPORTION="${READ_PROPORTION:-0.5}"
UPDATE_PROPORTION="${UPDATE_PROPORTION:-0.5}"
REQUEST_DISTRIBUTION="${REQUEST_DISTRIBUTION:-uniform}"

# Latte thread/concurrency: threads = min(inflight, hint), concurrency = inflight/threads
LATTE_THREADS_HINT="${LATTE_THREADS_HINT:-16}"

# Monitoring
MONITOR_INTERVAL=5

# Local paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARKS_DIR="${BENCHMARKS_DIR:-$SCRIPT_DIR}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/benchmark-results-local}"
# shellcheck source=benchmark-hot-common.sh
source "$SCRIPT_DIR/benchmark-hot-common.sh"
# shellcheck source=benchmark-latency-common.sh
source "$SCRIPT_DIR/benchmark-latency-common.sh"

###############################################################################
# Internal state
###############################################################################
SCYLLA_IP=""

log()  { echo ">>> [$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

###############################################################################
# Helpers
###############################################################################

compute_latte_params() {
    local inflight="$1"
    local max_threads="${LATTE_THREADS_HINT}"
    local threads
    if (( inflight <= max_threads )); then
        threads=$inflight
    else
        threads=$max_threads
    fi
    local concurrency=$(( inflight / threads ))
    echo "$threads $concurrency"
}

###############################################################################
# Discovery
###############################################################################
find_containers() {
    SCYLLA_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${SCYLLA_CONTAINER_PREFIX}-1" 2>/dev/null || true)
}

containers_exist() {
    [[ -n "$SCYLLA_IP" ]]
}

###############################################################################
# Pre-flight checks
###############################################################################
preflight() {
    log "Running pre-flight checks..."
    docker info &>/dev/null || die "Docker not running."
}

###############################################################################
# Setup Scylla
###############################################################################
setup_scylla() {
    log "Starting Scylla cluster ($SCYLLA_NODES nodes) with $SCYLLA_CPUS CPUs per node..."
    docker network create "$NETWORK_NAME" 2>/dev/null || true
    
    local SEED_IP=""
    for ((i=1; i<=SCYLLA_NODES; i++)); do
        local node_name="${SCYLLA_CONTAINER_PREFIX}-$i"
        log "Starting $node_name..."
        
        local seed_arg=""
        if [[ $i -gt 1 ]]; then
            seed_arg="--seeds=$SEED_IP"
        fi

        docker run -d --name "$node_name" --network "$NETWORK_NAME" \
            --cpus="$SCYLLA_CPUS" \
            -p $((8000+i-1)):8000 -p $((9042+i-1)):9042 -p $((9180+i-1)):9180 \
            "$SCYLLA_IMAGE" \
            --alternator-port=8000 \
            --alternator-write-isolation="$ALTERNATOR_WRITE_ISOLATION" \
            --batch-size-warn-threshold-in-kb=1024 \
            --developer-mode=1 \
            $seed_arg

        if [[ $i -eq 1 ]]; then
            SEED_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$node_name")
        fi
    done

    log "Waiting for all nodes to become healthy..."
    for ((i=1; i<=60; i++)); do
        local all_up=true
        for ((n=1; n<=SCYLLA_NODES; n++)); do
             if ! docker exec "${SCYLLA_CONTAINER_PREFIX}-$n" cqlsh -e "select * from system.local WHERE key='local'" &>/dev/null; then
                 all_up=false
                 break
             fi
        done
        
        if [[ "$all_up" == "true" ]]; then
            # Also check node count via nodetool
            local live_nodes
            live_nodes=$(docker exec "${SCYLLA_CONTAINER_PREFIX}-1" nodetool status | awk '/^UN/ {n++} END {print n+0}')
            if [[ "$live_nodes" -ge "$SCYLLA_NODES" ]]; then
                log "Scylla cluster is healthy with $live_nodes nodes"
                find_containers
                return 0
            fi
        fi
        sleep 5
    done
    die "Scylla cluster did not become healthy within 300s"
}

check_cluster_healthy() {
    for ((n=1; n<=SCYLLA_NODES; n++)); do
        if ! docker exec "${SCYLLA_CONTAINER_PREFIX}-$n" cqlsh -e "SELECT peer FROM system.peers" &>/dev/null; then
            return 1
        fi
    done
    local live_nodes
    live_nodes=$(docker exec "${SCYLLA_CONTAINER_PREFIX}-1" nodetool status | awk '/^UN/ {n++} END {print n+0}')
    if [[ "$live_nodes" -lt "$SCYLLA_NODES" ]]; then
        log "WARN: Cluster health check: $live_nodes/$SCYLLA_NODES nodes UP"
        return 1
    fi
    return 0
}

###############################################################################
# Setup Loader (Local: just verify images)
###############################################################################
setup_loader() {
    log "Loader will run as ephemeral docker containers on the same network."
}

###############################################################################
# Build local Docker images
###############################################################################
build_local_images() {
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running. Start Docker first."
    fi

    log "Building latte-alternator Docker image locally..."
    docker build -t latte-alternator -f "$BENCHMARKS_DIR/Dockerfile.latte" "$BENCHMARKS_DIR"
    log "Latte image built"

    log "Building latte-alternator-new Docker image locally..."
    docker build -t latte-alternator-new -f "$BENCHMARKS_DIR/Dockerfile.latte-new" "$BENCHMARKS_DIR"
    log "Latte-new image built"

    log "Local images ready:"
    docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}  ({{.CreatedSince}})' | grep -E 'latte-alternator'
}

verify_local_images() {
    if ! docker image inspect latte-alternator >/dev/null 2>&1; then
        die "Latte image not found locally. Run: ./local-benchmark.sh build"
    fi
    if ! docker image inspect latte-alternator-new >/dev/null 2>&1; then
        die "Latte-new image not found locally. Run: ./local-benchmark.sh build"
    fi
    log "Local images verified"
}

###############################################################################
# Load data
###############################################################################
load_data() {
    local phase_name="${1:-}"
    local wl="performance.rn"
    local phase_table="$TABLE"
    local -a extra_args=()

    if [[ "$phase_name" == *"-hot" ]]; then
        wl="hot_partition.rn"
        phase_table="$HOT_TABLE"
        compute_hot_keyspace_params
        extra_args+=(
            -P "hot_partitions=${HOT_PARTITIONS}"
            -P "hot_items_per_partition=${HOT_ITEMS_PER_PARTITION}"
            -P "cold_partitions=${COLD_PARTITIONS}"
        )
    else
        extra_args+=(
            -P "row_count=${ROW_COUNT}"
            -P 'requestdistribution="uniform"'
        )
    fi

    log_load_data "$phase_name" "$wl"

    local endpoints_str=""
    for ((n=1; n<=SCYLLA_NODES; n++)); do
        endpoints_str+="http://${SCYLLA_CONTAINER_PREFIX}-$n:8000 "
    done
    endpoints_str="${endpoints_str% }"

    docker run --rm --network "$NETWORK_NAME" \
      -v "$BENCHMARKS_DIR/${wl}:/${wl}:ro" \
      --entrypoint latte-alternator \
      latte-alternator \
      schema /${wl} $endpoints_str \
        -P "table=\"${phase_table}\""

    docker run --rm --network "$NETWORK_NAME" \
      -v "$BENCHMARKS_DIR/${wl}:/${wl}:ro" \
      --entrypoint latte-alternator \
      latte-alternator \
      load /${wl} $endpoints_str \
        -t 8 --concurrency 128 \
        -P "table=\"${phase_table}\"" \
        -P "fieldcount=${FIELDCOUNT}" \
        -P "fieldlength=${FIELDLENGTH}" \
        "${extra_args[@]}"
    log "Data loaded"
}

###############################################################################
# Monitoring — local version
###############################################################################
start_monitoring() {
    local tag="$1"
    log "Starting monitoring: $tag"
    mkdir -p "$RESULTS_DIR/monitor"
    
    # Use docker stats to track per-container CPU usage
    # This is much more accurate for local runs than mpstat
    nohup bash -c "while true; do \
        echo \"---TIMESTAMP \$(date +%s)---\"; \
        docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}'; \
        sleep ${MONITOR_INTERVAL}; \
    done" > "$RESULTS_DIR/monitor/${tag}_docker_stats.log" 2>&1 &
    echo $! > "$RESULTS_DIR/monitor/${tag}_pids"

    # Prometheus scrape all Scylla nodes (ports 9180..9180+N-1)
    local prom_ports
    prom_ports=$(seq -s ' ' 9180 $((9179 + SCYLLA_NODES)))
    nohup bash -c "while true; do \
        echo \"---TIMESTAMP \$(date +%s)---\"; \
        for p in ${prom_ports}; do \
            echo \"---NODE \$p---\"; \
            curl -s http://localhost:\$p/metrics 2>/dev/null || true; \
        done; \
        sleep ${MONITOR_INTERVAL}; \
    done" > "$RESULTS_DIR/monitor/${tag}_prometheus.log" 2>&1 &
    echo $! >> "$RESULTS_DIR/monitor/${tag}_pids"
}

stop_monitoring() {
    local tag="$1"
    local pidfile="$RESULTS_DIR/monitor/${tag}_pids"
    if [ -f "$pidfile" ]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$pidfile"
        rm -f "$pidfile"
    fi
}

collect_monitoring() {
    local tag="$1"
    local dest="$2"
    mkdir -p "$dest"
    cp "$RESULTS_DIR/monitor/${tag}_docker_stats.log" "$dest/docker_stats.log" 2>/dev/null || true
    cp "$RESULTS_DIR/monitor/${tag}_prometheus.log" "$dest/scylla_prometheus.log" 2>/dev/null || true
}

###############################################################################
# Run a single benchmark pass
###############################################################################
run_one_pass() {
    local tool="$1"
    local inflight="$2"
    local run_tag="$3"
    local out_dir="$4"

    local wl="performance.rn"
    local phase_table="$TABLE"
    local hot_items=""
    local hot_partitions=""
    local hot_items_per_partition=""
    local cold_partitions=""

    local hot_traffic_ratio=""

    if is_hot_phase "$run_tag"; then
        wl="hot_partition.rn"
        phase_table="$HOT_TABLE"
        compute_hot_keyspace_params
        hot_items="$HOT_ITEMS"
        hot_partitions="$HOT_PARTITIONS"
        hot_items_per_partition="$HOT_ITEMS_PER_PARTITION"
        cold_partitions="$COLD_PARTITIONS"
        hot_traffic_ratio="$HOT_TRAFFIC_RATIO"
        check_cluster_healthy || die "Cluster unhealthy before $run_tag"
    fi

    mkdir -p "$out_dir"
    start_monitoring "$run_tag"

    local output_vol="$out_dir"
    # Ensure out_dir is absolute for docker volume mapping
    output_vol=$(cd "$out_dir" && pwd)

    local endpoints_str=""
    for ((n=1; n<=SCYLLA_NODES; n++)); do
        endpoints_str+="http://${SCYLLA_CONTAINER_PREFIX}-$n:8000 "
    done
    # Trim trailing space
    endpoints_str="${endpoints_str% }"

    if [[ "$tool" == "latte" ]]; then
        local params
        params=$(compute_latte_params "$inflight")
        local threads=${params%% *}
        local concurrency=${params##* }
        log "  Latte: inflight=$inflight (${threads}t x ${concurrency}c) workload=$wl duration=${RUN_DURATION_SEC}s warmup=${WARMUP_SEC}s rate=${RATE:-unlimited}${hot_traffic_ratio:+ hot_ratio=$hot_traffic_ratio}"
        docker run --cpus="8" --rm --network "$NETWORK_NAME" --name "$LOADER_CONTAINER" \
          -v "$output_vol:/output" \
          -v "$BENCHMARKS_DIR/${wl}:/${wl}:ro" \
          -e ALT_ENDPOINT="$endpoints_str" \
          -e TABLE="${phase_table}" \
          -e ROW_COUNT="${ROW_COUNT}" \
          -e THREADS="${threads}" \
          -e CONCURRENCY="${concurrency}" \
          -e FIELDCOUNT="${FIELDCOUNT}" \
          -e FIELDLENGTH="${FIELDLENGTH}" \
          -e READ_PROPORTION="${READ_PROPORTION}" \
          -e UPDATE_PROPORTION="${UPDATE_PROPORTION}" \
          -e REQUEST_DISTRIBUTION="${REQUEST_DISTRIBUTION}" \
          -e RUN_DURATION_SEC="${RUN_DURATION_SEC}" \
          -e WARMUP_SEC="${WARMUP_SEC}" \
          -e RATE="${RATE}" \
          -e OUTDIR=/output \
          -e LATTE_WORKLOAD=/${wl} \
          -e HOT_ITEMS="${hot_items}" \
          -e HOT_PARTITIONS="${hot_partitions}" \
          -e HOT_ITEMS_PER_PARTITION="${hot_items_per_partition}" \
          -e COLD_PARTITIONS="${cold_partitions}" \
          -e HOT_TRAFFIC_RATIO="${hot_traffic_ratio}" \
          latte-alternator

    elif [[ "$tool" == "latte-new-rr" || "$tool" == "latte-new-affinity" ]]; then
        local params
        params=$(compute_latte_params "$inflight")
        local threads=${params%% *}
        local concurrency=${params##* }
        local lb_policy="round-robin"
        [[ "$tool" == "latte-new-affinity" ]] && lb_policy="affinity-key-routing"

        log "  Latte-New ($tool): inflight=$inflight (${threads}t x ${concurrency}c) workload=$wl policy=$lb_policy duration=${RUN_DURATION_SEC}s warmup=${WARMUP_SEC}s rate=${RATE:-unlimited}${hot_traffic_ratio:+ hot_ratio=$hot_traffic_ratio}"
        docker run --cpus="8" --rm --network "$NETWORK_NAME" --name "$LOADER_CONTAINER" \
          -v "$output_vol:/output" \
          -v "$BENCHMARKS_DIR/${wl}:/${wl}:ro" \
          -e ALT_ENDPOINT="$endpoints_str" \
          -e TABLE="${phase_table}" \
          -e ROW_COUNT="${ROW_COUNT}" \
          -e THREADS="${threads}" \
          -e CONCURRENCY="${concurrency}" \
          -e FIELDCOUNT="${FIELDCOUNT}" \
          -e FIELDLENGTH="${FIELDLENGTH}" \
          -e READ_PROPORTION="${READ_PROPORTION}" \
          -e UPDATE_PROPORTION="${UPDATE_PROPORTION}" \
          -e REQUEST_DISTRIBUTION="${REQUEST_DISTRIBUTION}" \
          -e RUN_DURATION_SEC="${RUN_DURATION_SEC}" \
          -e WARMUP_SEC="${WARMUP_SEC}" \
          -e RATE="${RATE}" \
          -e OUTDIR=/output \
          -e LATTE_WORKLOAD=/${wl} \
          -e HOT_ITEMS="${hot_items}" \
          -e HOT_PARTITIONS="${hot_partitions}" \
          -e HOT_ITEMS_PER_PARTITION="${hot_items_per_partition}" \
          -e COLD_PARTITIONS="${cold_partitions}" \
          -e HOT_TRAFFIC_RATIO="${hot_traffic_ratio}" \
          -e LATTE_BINARY=latte-alternator-new \
          -e LB_POLICY="$lb_policy" \
          -e REQUEST_COMPRESSION="off" \
          -e KEY_ROUTE_AFFINITY_MODE="${KEY_ROUTE_AFFINITY_MODE}" \
          latte-alternator-new
    fi

    validate_benchmark_log "$out_dir/latte_1.log" || true

    stop_monitoring "$run_tag"
    collect_monitoring "$run_tag" "$out_dir"
}

###############################################################################
# Parse results — extended CSV with both latency types + server metrics
#
# CSV header:
#   tool,inflight,rate,rep,ops_per_sec,
#   get_cycle_mean_ms,get_cycle_p99_ms,upd_cycle_mean_ms,upd_cycle_p99_ms,
#   agg_request_mean_ms,agg_request_p99_ms,
#   loader_cpu_pct,scylla_cpu_pct,scylla_max_node_cpu_avg_pct,
#   scylla_ops_per_sec,scylla_p99_ms,scylla_reactor_util_pct,
#   scylla_max_node_ops_per_sec,scylla_ops_imbalance_ratio
###############################################################################
CSV_HEADER="tool,inflight,rate,rep,ops_per_sec,get_cycle_mean_ms,get_cycle_p99_ms,upd_cycle_mean_ms,upd_cycle_p99_ms,agg_request_mean_ms,agg_request_p99_ms,loader_cpu_pct,scylla_cpu_pct,scylla_max_node_cpu_avg_pct,scylla_ops_per_sec,scylla_p99_ms,scylla_reactor_util_pct,scylla_max_node_ops_per_sec,scylla_ops_imbalance_ratio"

# Extract average CPU% from docker stats log
parse_docker_cpu() {
    local logfile="$1"
    local container_pattern="$2"
    if [[ -f "$logfile" ]]; then
        # docker stats output: name cpu% ...
        # We find lines matching the pattern and average the CPU% (removing the % sign)
        awk -v pat="$container_pattern" '$1 ~ pat { gsub(/%/, "", $2); sum+=$2; n++ } END { if(n>0) printf "%.1f", sum/n; else print "0" }' "$logfile" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Max of per-node time-averaged CPU (hottest node by sustained utilization).
parse_scylla_max_node_cpu_avg() {
    local out_dir="$1"
    local max=0 avg=0 n log

    for log in "$out_dir"/scylla*_cpu.log; do
        [[ -f "$log" ]] || continue
        if declare -f parse_cpu_pct &>/dev/null; then
            avg=$(parse_cpu_pct "$log")
        else
            avg=$(awk '/^ *[0-9].*all/ { idle+=$NF; n++ } END { if(n>0) printf "%.1f", 100-idle/n; else print "0" }' "$log" 2>/dev/null || echo "0")
        fi
        if awk -v a="$avg" -v m="$max" 'BEGIN { exit !(a > m) }'; then
            max=$avg
        fi
    done

    if awk -v m="$max" 'BEGIN { exit !(m > 0) }'; then
        echo "$max"
        return
    fi

    for ((n=1; n<=SCYLLA_NODES; n++)); do
        avg=$(parse_docker_cpu "$out_dir/docker_stats.log" "${SCYLLA_CONTAINER_PREFIX}-${n}")
        if awk -v a="$avg" -v m="$max" 'BEGIN { exit !(a > m) }'; then
            max=$avg
        fi
    done
    echo "$max"
}

parse_result_line() {
    local tool="$1"
    local inflight="$2"
    local rate_val="$3"
    local rep="$4"
    local out_dir="$5"

    local rate_str="${rate_val:-unlimited}"
    local loader_cpu scylla_cpu scylla_max_node_cpu_avg
    loader_cpu=$(parse_docker_cpu "$out_dir/docker_stats.log" "$LOADER_CONTAINER")
    scylla_cpu=$(parse_docker_cpu "$out_dir/docker_stats.log" "$SCYLLA_CONTAINER_PREFIX")
    scylla_max_node_cpu_avg=$(parse_scylla_max_node_cpu_avg "$out_dir")

    # Scylla server-side metrics from Prometheus
    local scylla_ops="0" scylla_p99="0" scylla_reactor="0" scylla_max_node_ops="0" scylla_imbalance="0"
    if [[ -f "$out_dir/scylla_prometheus.log" ]]; then
        local prom_json
        prom_json=$(python3 "$BENCHMARKS_DIR/analyze_scylla_metrics.py" "$out_dir/scylla_prometheus.log" 2>/dev/null || echo "{}")
        scylla_ops=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ops_per_sec','0'))" 2>/dev/null || echo "0")
        scylla_p99=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('p99_ms','0'))" 2>/dev/null || echo "0")
        scylla_reactor=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('reactor_util_pct','0'))" 2>/dev/null || echo "0")
        scylla_max_node_ops=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('max_node_ops_per_sec','0'))" 2>/dev/null || echo "0")
        scylla_imbalance=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ops_imbalance_ratio','0'))" 2>/dev/null || echo "0")
    fi

    if [[ "$tool" == latte* ]]; then
        local jsonfile="$out_dir/latte_1.json"
        if [[ -f "$jsonfile" ]]; then
            python3 "$BENCHMARKS_DIR/analyze_latte_results.py" "$out_dir" \
                --csv-prefix "$tool,$inflight,$rate_str,$rep" \
                --csv-suffix "$loader_cpu,$scylla_cpu,$scylla_max_node_cpu_avg,$scylla_ops,$scylla_p99,$scylla_reactor,$scylla_max_node_ops,$scylla_imbalance"
        fi
    fi
}

###############################################################################
# Run a complete benchmark phase
###############################################################################
run_phase() {
    local phase_name="$1"
    local phase_dir="$RESULTS_DIR/$phase_name"
    mkdir -p "$phase_dir"

    local csv="$phase_dir/summary.csv"
    echo "$CSV_HEADER" > "$csv"

    log "=== Phase: $phase_name ==="
    log "Duration: ${RUN_DURATION_SEC}s | Warmup: ${WARMUP_SEC}s | Rate: ${RATE:-unlimited}"
    log "Inflight: $INFLIGHT_LIST | Reps: $REPETITIONS | Rows: $ROW_COUNT"
    echo

    load_data "$phase_name"

    for inflight in $INFLIGHT_LIST; do
        for ((rep=1; rep<=REPETITIONS; rep++)); do
            local tools
            if is_hot_phase "$phase_name"; then
                tools=$(hot_phase_tools "$rep")
            elif (( rep % 2 == 1 )); then
                tools="latte latte-new-rr latte-new-affinity"
            else
                tools="latte-new-affinity latte-new-rr latte"
            fi

            for tool in $tools; do
                local tag="${phase_name}_${tool}_inf${inflight}_r${rep}"
                local out_dir="$phase_dir/${tool}/inflight=${inflight}/rep${rep}"
                log "--- $tool | inflight=$inflight | rep=$rep ---"
                run_one_pass "$tool" "$inflight" "$tag" "$out_dir"

                local line
                line=$(parse_result_line "$tool" "$inflight" "$RATE" "$rep" "$out_dir")
                if [[ -n "$line" ]]; then
                    echo "$line" >> "$csv"
                    echo "  >> $line"
                fi
                if is_latency_phase "$phase_name"; then
                    validate_latency_run "$tool" "$out_dir" || true
                fi
                run_cooldown
                echo
            done
        done
    done

    log "Phase $phase_name complete. Summary: $csv"
    echo
    echo "=== $phase_name Summary ==="
    column -t -s',' "$csv" 2>/dev/null || cat "$csv"
    echo
}

###############################################################################
# Commands
###############################################################################

cmd_build() {
    log "=== Local build phase ==="
    build_local_images
    log "Build complete. Next: ./local-benchmark.sh provision"
}

cmd_provision() {
    preflight
    verify_local_images

    find_containers
    if containers_exist; then
        log "Existing Scylla cluster found (Seed IP: $SCYLLA_IP)"
        log "Reusing existing cluster. Use 'teardown' first to start fresh."
        return 0
    fi

    setup_scylla
    setup_loader

    log "Provision complete. Next: ./local-benchmark.sh run smoke"
}

cmd_teardown() {
    log "Stopping and removing containers..."
    for ((i=1; i<=SCYLLA_NODES; i++)); do
        docker rm -f "${SCYLLA_CONTAINER_PREFIX}-$i" 2>/dev/null || true
    done
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
    log "Teardown complete."
}

cmd_run() {
    local phase="${1:-}"
    [[ -z "$phase" ]] && die "Usage: ./local-benchmark.sh run {smoke|latency|throughput}"

    find_containers
    if ! containers_exist; then
        die "No active Scylla cluster. Run './local-benchmark.sh provision' first."
    fi
    log "Using Scylla cluster (Seed: ${SCYLLA_CONTAINER_PREFIX}-1 / $SCYLLA_IP)"

    case "$phase" in
        smoke)
            ROW_COUNT=10000
            RUN_DURATION_SEC=10
            WARMUP_SEC=0
            REPETITIONS=2
            RATE=500
            INFLIGHT_LIST="16"
            KEY_ROUTE_AFFINITY_MODE="any-write"
            # run_phase "smoke"
            run_phase_hot "smoke-hot"
            ;;
        latency)
            ROW_COUNT=100000
            RUN_DURATION_SEC=30
            WARMUP_SEC=10
            REPETITIONS=2
            apply_latency_phase_defaults
            log "Latency config: rate=$RATE inflight=$INFLIGHT_LIST threads_hint=$LATTE_THREADS_HINT"
            KEY_ROUTE_AFFINITY_MODE="any-write"
            # run_phase "latency"
            HOT_TRAFFIC_RATIO=0.99
            HOT_READ_PROPORTION=0.3
            HOT_UPDATE_PROPORTION=0.7
            run_phase_hot "latency-hot"
            ;;
        throughput)
            ROW_COUNT=100000
            RUN_DURATION_SEC=30
            WARMUP_SEC=10
            REPETITIONS=2
            RATE=""
            INFLIGHT_LIST="64 128"
            KEY_ROUTE_AFFINITY_MODE="any-write"
            # run_phase "throughput"
            RUN_DURATION_SEC=120
            WARMUP_SEC=30
            INFLIGHT_LIST="128 256"
            HOT_TRAFFIC_RATIO=0.99
            HOT_READ_PROPORTION=0.3
            HOT_UPDATE_PROPORTION=0.7
            run_phase_hot "throughput-hot"
            ;;
        *)
            die "Unknown phase: $phase. Valid: smoke, latency, throughput"
            ;;
    esac
}

cmd_report() {
    log "Aggregating results..."
    echo
    for csv in "$RESULTS_DIR"/*/summary.csv; do
        [[ -f "$csv" ]] || continue
        local phase
        phase=$(basename "$(dirname "$csv")")
        echo "=== $phase ==="
        column -t -s',' "$csv" 2>/dev/null || cat "$csv"
        echo
    done
}

###############################################################################
# Main
###############################################################################
main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        build)      cmd_build ;;
        provision)  cmd_provision ;;
        teardown)   cmd_teardown ;;
        run)        cmd_run "$@" ;;
        report)     cmd_report ;;
        *)
            echo "Usage: $0 {build|provision|teardown|run <phase>|report}"
            echo
            echo "Phases: smoke, latency, throughput"
            echo
            echo "Workflow:"
            echo "  1. $0 build       # Local: docker build + pull"
            echo "  2. $0 provision    # Start Scylla container"
            echo "  3. $0 run smoke    # Validate pipeline + parsers (+ hot copy)"
            echo "  4. $0 run latency  # Single-node overload vs balanced (+ hot copy)"
            echo "  5. $0 run throughput # Saturated comparison (+ hot copy)"
            echo "  6. $0 report       # Show all results"
            echo "  7. $0 teardown     # Remove containers"
            exit 1
            ;;
    esac
}

main "$@"
