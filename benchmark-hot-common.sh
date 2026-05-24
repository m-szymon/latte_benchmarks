#!/usr/bin/env bash
#
# Shared hot-partition benchmark configuration and helpers.
# Sourced by local-benchmark.sh and aws-benchmark.sh.
#

: "${HOT_TRAFFIC_RATIO:=0.99}"
: "${HOT_READ_PROPORTION:=0.3}"
: "${HOT_UPDATE_PROPORTION:=0.7}"
: "${RUN_COOLDOWN_SEC:=${HOT_COOLDOWN_SEC:-15}}"
: "${HOT_COOLDOWN_SEC:=$RUN_COOLDOWN_SEC}"
: "${HOT_PARTITIONS:=32}"

run_cooldown() {
    log "Cooldown (${RUN_COOLDOWN_SEC}s) before next run..."
    sleep "$RUN_COOLDOWN_SEC"
}

is_hot_phase() {
    [[ "$1" == *"-hot"* ]]
}

# Derive hot keyspace sizing from ROW_COUNT and HOT_PARTITIONS.
# Sets: HOT_ITEMS, HOT_ITEMS_PER_PARTITION, COLD_PARTITIONS
compute_hot_keyspace_params() {
    local hot_items_total=$(( ROW_COUNT / 10 ))
    local hot_partitions="$HOT_PARTITIONS"
    local hot_items_per_partition=$(( hot_items_total / hot_partitions ))

    if (( hot_items_per_partition < 1 )); then
        hot_items_per_partition=1
        hot_partitions=$hot_items_total
    fi

    HOT_ITEMS=$(( hot_partitions * hot_items_per_partition ))
    HOT_ITEMS_PER_PARTITION=$hot_items_per_partition
    HOT_PARTITIONS=$hot_partitions
    COLD_PARTITIONS=$(( ROW_COUNT - HOT_ITEMS ))
}

apply_hot_phase_defaults() {
    READ_PROPORTION="$HOT_READ_PROPORTION"
    UPDATE_PROPORTION="$HOT_UPDATE_PROPORTION"
    compute_hot_keyspace_params
}

log_load_data() {
    local phase_name="$1"
    local wl="$2"
    if [[ "$phase_name" == *"-hot" ]]; then
        log "Loading hot keyspace (partitions=${HOT_PARTITIONS} items/partition=${HOT_ITEMS_PER_PARTITION} cold=${COLD_PARTITIONS}) using $wl..."
    else
        log "Loading $ROW_COUNT rows into Scylla using $wl..."
    fi
}

validate_benchmark_log() {
    local logfile="$1"
    [[ -f "$logfile" ]] || return 0

    if grep -qE 'unavailable_exception|Cannot achieve consistency level|alive [0-9]+' "$logfile"; then
        log "WARN: Cluster errors in $(basename "$logfile") — results may be unreliable"
        grep -E 'unavailable_exception|Cannot achieve consistency level' "$logfile" | head -3 >&2 || true
        return 1
    fi
    return 0
}

run_phase_hot() {
    local phase_name="$1"
    local prev_read="$READ_PROPORTION"
    local prev_update="$UPDATE_PROPORTION"
    local prev_hot_traffic="$HOT_TRAFFIC_RATIO"
    local prev_hot_partitions="$HOT_PARTITIONS"
    local prev_hot_read="$HOT_READ_PROPORTION"
    local prev_hot_update="$HOT_UPDATE_PROPORTION"

    apply_hot_phase_defaults
    log "Hot phase config: hot_traffic_ratio=$HOT_TRAFFIC_RATIO hot_partitions=$HOT_PARTITIONS hot_items_per_partition=$HOT_ITEMS_PER_PARTITION hot_items=$HOT_ITEMS cold_partitions=$COLD_PARTITIONS read=$READ_PROPORTION update=$UPDATE_PROPORTION"
    run_phase "$phase_name"

    READ_PROPORTION="$prev_read"
    UPDATE_PROPORTION="$prev_update"
    HOT_TRAFFIC_RATIO="$prev_hot_traffic"
    HOT_PARTITIONS="$prev_hot_partitions"
    HOT_READ_PROPORTION="$prev_hot_read"
    HOT_UPDATE_PROPORTION="$prev_hot_update"
}

hot_phase_tools() {
    local rep="${1:-1}"
    # Alternate routing-policy order by rep to reduce cache/order bias.
    if (( rep % 2 == 1 )); then
        echo "latte-new-rr latte-new-affinity latte"
    else
        echo "latte-new-affinity latte-new-rr latte"
    fi
}
