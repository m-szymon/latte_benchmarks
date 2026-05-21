#!/usr/bin/env bash
#
# aws-benchmark.sh — Verification benchmark: Latte drivers on Alternator.
#
# Usage:
#   ./aws-benchmark.sh build           # Local: docker build latte
#   ./aws-benchmark.sh provision       # EC2: launch + setup + ship images
#   ./aws-benchmark.sh run smoke       # Sanity check (60s, 1 rep) — validates parsers
#   ./aws-benchmark.sh run latency     # Rate-limited comparison (120s, 2 reps)
#   ./aws-benchmark.sh run throughput  # Saturated comparison (120s, 2 reps, 2 inflights)
#   ./aws-benchmark.sh teardown        # Destroy tagged instances
#   ./aws-benchmark.sh report          # Aggregate all summary.csv tables
#
set -euo pipefail

###############################################################################
# Configuration
###############################################################################

# AWS
REGION="${REGION:-eu-central-1}"
KEY_NAME="${KEY_NAME:-latte-bench-key}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
SG_NAME="${SG_NAME:-latte-bench-sg}"
VPC_ID="${VPC_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
OWNER_TAG="${OWNER_TAG:-$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null | sed 's/.*\///' || echo unknown)}"
BENCH_TAG="${BENCH_TAG:-latte-bench-active}"

# Instance types — single tier, proven in explore/ Phase 6
SCYLLA_INSTANCE_TYPE="${SCYLLA_INSTANCE_TYPE:-i3.2xlarge}"
LOADER_INSTANCE_TYPE="${LOADER_INSTANCE_TYPE:-c5.4xlarge}"

# Scylla
SCYLLA_IMAGE="${SCYLLA_IMAGE:-scylladb/scylla-nightly:2026.1.0-dev-0.20251003.20aeed160740-x86_64}"
ALTERNATOR_WRITE_ISOLATION="${ALTERNATOR_WRITE_ISOLATION:-only_rmw_uses_lwt}"

# Workload parameters
TABLE="${TABLE:-latte_performance}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
READ_PROPORTION="${READ_PROPORTION:-0.5}"
UPDATE_PROPORTION="${UPDATE_PROPORTION:-0.5}"

# Latte thread/concurrency: threads = min(inflight, hint), concurrency = inflight/threads
LATTE_THREADS_HINT="${LATTE_THREADS_HINT:-8}"

# Monitoring
MONITOR_INTERVAL=5

# Local paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARKS_DIR="${BENCHMARKS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/benchmark-results}"

###############################################################################
# Internal state
###############################################################################
SCYLLA_INSTANCE_ID=""
LOADER_INSTANCE_ID=""
SCYLLA_PUBLIC_IP=""
SCYLLA_PRIVATE_IP=""
LOADER_PUBLIC_IP=""
SG_ID=""
AMI_ID=""

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=60 -o ServerAliveCountMax=10"

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

remote() {
    local host="$1"; shift
    ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host" "$@"
}

###############################################################################
# Tag-based instance discovery
###############################################################################
find_tagged_instances() {
    local query
    query=$(aws ec2 describe-instances --region "$REGION" \
        --filters \
            "Name=tag:BenchGroup,Values=$BENCH_TAG" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`].Value | [0], PublicIpAddress, PrivateIpAddress]' \
        --output text 2>/dev/null || true)

    SCYLLA_INSTANCE_ID=""
    LOADER_INSTANCE_ID=""
    SCYLLA_PUBLIC_IP=""
    SCYLLA_PRIVATE_IP=""
    LOADER_PUBLIC_IP=""

    while IFS=$'\t' read -r id name pub priv; do
        [[ -z "$id" ]] && continue
        if [[ "$name" == *scylla* ]]; then
            SCYLLA_INSTANCE_ID="$id"
            SCYLLA_PUBLIC_IP="$pub"
            SCYLLA_PRIVATE_IP="$priv"
        elif [[ "$name" == *loader* ]]; then
            LOADER_INSTANCE_ID="$id"
            LOADER_PUBLIC_IP="$pub"
        fi
    done <<< "$query"
}

instances_exist() {
    [[ -n "$SCYLLA_INSTANCE_ID" && -n "$LOADER_INSTANCE_ID" ]]
}

###############################################################################
# Pre-flight checks
###############################################################################
preflight() {
    log "Running pre-flight checks..."
    command -v aws &>/dev/null || die "AWS CLI not found."
    aws sts get-caller-identity --region "$REGION" &>/dev/null || die "AWS credentials not configured."
    log "AWS credentials OK ($(aws sts get-caller-identity --query 'Account' --output text --region "$REGION"))"
}

###############################################################################
# SSH key pair
###############################################################################
ensure_key_pair() {
    if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &>/dev/null; then
        [[ -f "$KEY_FILE" ]] || die "Key pair '$KEY_NAME' exists in AWS but local file $KEY_FILE is missing."
        log "Using existing key pair: $KEY_NAME"
    else
        log "Creating key pair: $KEY_NAME"
        mkdir -p "$(dirname "$KEY_FILE")"
        aws ec2 create-key-pair --region "$REGION" \
            --key-name "$KEY_NAME" \
            --query 'KeyMaterial' --output text > "$KEY_FILE"
        chmod 400 "$KEY_FILE"
        log "Key saved to $KEY_FILE"
    fi
}

###############################################################################
# VPC and subnet
###############################################################################
find_vpc_and_subnet() {
    if [[ -z "$VPC_ID" ]]; then
        log "Auto-detecting VPC..."
        VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
        if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
            VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
                --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
        fi
        [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && die "No VPC found in $REGION."
    fi
    log "VPC: $VPC_ID"

    if [[ -z "$SUBNET_ID" ]]; then
        SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")
        if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
            SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")
        fi
        [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && die "No subnet found in VPC $VPC_ID."
    fi
    log "Subnet: $SUBNET_ID"
}

###############################################################################
# Security group
###############################################################################
ensure_security_group() {
    SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

    if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
        log "Creating security group: $SG_NAME"
        SG_ID=$(aws ec2 create-security-group --region "$REGION" \
            --group-name "$SG_NAME" \
            --description "Latte benchmark - SSH, Alternator, CQL, metrics" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' --output text)
        for port in 22 8000 9042 9180; do
            aws ec2 authorize-security-group-ingress --region "$REGION" \
                --group-id "$SG_ID" --protocol tcp --port "$port" --cidr 0.0.0.0/0 >/dev/null
        done
        log "Security group created: $SG_ID"
    else
        log "Using existing security group: $SG_NAME ($SG_ID)"
    fi
}

###############################################################################
# AMI
###############################################################################
find_ami() {
    log "Looking up latest Ubuntu 24.04 AMI..."
    AMI_ID=$(aws ec2 describe-images --region "$REGION" \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
    [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]] && die "Could not find Ubuntu 24.04 AMI in $REGION"
    log "AMI: $AMI_ID"
}

###############################################################################
# Launch EC2 instance with i3 -> i4i fallback
###############################################################################
launch_instance() {
    local instance_type="$1"
    local name="$2"

    local result
    if result=$(aws ec2 run-instances --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$instance_type" \
        --key-name "$KEY_NAME" \
        --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,AssociatePublicIpAddress=true,Groups=$SG_ID" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Owner,Value=$OWNER_TAG},{Key=BenchGroup,Value=$BENCH_TAG}]" \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3}' \
        --query 'Instances[0].InstanceId' --output text 2>&1); then
        echo "$result"
        return 0
    fi

    if [[ "$instance_type" == i3.* ]]; then
        local fallback="${instance_type/i3./i4i.}"
        log "WARN: $instance_type failed, trying fallback $fallback"
        aws ec2 run-instances --region "$REGION" \
            --image-id "$AMI_ID" \
            --instance-type "$fallback" \
            --key-name "$KEY_NAME" \
            --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,AssociatePublicIpAddress=true,Groups=$SG_ID" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Owner,Value=$OWNER_TAG},{Key=BenchGroup,Value=$BENCH_TAG}]" \
            --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3}' \
            --query 'Instances[0].InstanceId' --output text
    else
        echo "$result" >&2
        return 1
    fi
}

###############################################################################
# Wait for SSH
###############################################################################
wait_for_ssh() {
    local host="$1"
    local max_retries=60
    log "Waiting for SSH on $host..."
    for ((i=1; i<=max_retries; i++)); do
        if ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host" true 2>/dev/null; then
            log "SSH ready on $host"
            return 0
        fi
        sleep 5
    done
    die "SSH timeout on $host"
}

###############################################################################
# Setup Scylla
###############################################################################
setup_scylla() {
    local host="$SCYLLA_PUBLIC_IP"
    log "Setting up Scylla on $host..."

    remote "$host" bash -s <<'SCYLLA_APT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3 4 5; do sudo apt-get update -qq && break || sleep 15; done
sudo apt-get install -y -qq docker.io docker-compose nvme-cli parted sysstat
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
SCYLLA_APT
    log "Docker installed on Scylla node"

    remote "$host" bash -s <<'MOUNT_SCRIPT'
set -euo pipefail
DEVICE=""
for dev in /dev/nvme*n1; do
    [ -b "$dev" ] || continue
    MODEL=$(cat "/sys/class/block/$(basename "$dev")/device/model" 2>/dev/null | xargs)
    if [[ "$MODEL" != *"Amazon Elastic Block Store"* ]]; then
        DEVICE="$dev"
        break
    fi
done
if [ -z "$DEVICE" ]; then
    echo "WARN: No NVMe instance store found, using EBS root volume"
    sudo mkdir -p /mnt/data/scylla
    sudo chmod a+w /mnt/data/scylla
    exit 0
fi
echo "Using instance store device: $DEVICE"
PARTITION="${DEVICE}p1"
sudo mkdir -p /mnt/data
sudo parted "$DEVICE" --script mklabel gpt mkpart P1 ext4 1MiB 100%
sudo mkfs.ext4 -q "$PARTITION"
sudo mount -t auto -v "$PARTITION" /mnt/data
sudo mkdir -p /mnt/data/scylla
sudo chmod a+w /mnt/data/scylla
MOUNT_SCRIPT
    log "Storage mounted"

    remote "$host" bash -s <<COMPOSE_SCRIPT
set -euo pipefail
mkdir -p ~/scylla && cd ~/scylla
cat > docker-compose.yml <<'YAML'
services:
  scylladb:
    container_name: scylla-alternator
    image: ${SCYLLA_IMAGE}
    command: >
      --alternator-port=8000
      --alternator-write-isolation=${ALTERNATOR_WRITE_ISOLATION}
      --batch-size-warn-threshold-in-kb=1024
    healthcheck:
      test: ["CMD", "cqlsh", "-e", "select * from system.local WHERE key='local'"]
      interval: 1s
      timeout: 5s
      retries: 60
    ports:
      - "8000:8000"
      - "9042:9042"
      - "9180:9180"
    volumes:
      - /mnt/data/scylla:/var/lib/scylla
YAML
sudo docker-compose up -d
COMPOSE_SCRIPT
    log "Scylla container starting..."

    log "Waiting for Scylla to become healthy..."
    for ((i=1; i<=120; i++)); do
        if remote "$host" "sudo docker exec scylla-alternator cqlsh -e \"select * from system.local WHERE key='local'\"" &>/dev/null; then
            log "Scylla is healthy"
            return 0
        fi
        sleep 5
    done
    die "Scylla did not become healthy within 600s"
}

###############################################################################
# Setup Loader
###############################################################################
setup_loader() {
    local host="$LOADER_PUBLIC_IP"
    log "Setting up Loader on $host..."

    remote "$host" bash -s <<'LOADER_APT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3 4 5; do sudo apt-get update -qq && break || sleep 15; done
sudo apt-get install -y -qq docker.io sysstat
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
LOADER_APT
    log "Docker installed on Loader node"
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
    docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}  ({{.CreatedSince}})' latte-alternator
}

verify_local_images() {
    if ! docker image inspect latte-alternator >/dev/null 2>&1; then
        die "Latte image not found locally. Run: ./aws-benchmark.sh build"
    fi
    if ! docker image inspect latte-alternator-new >/dev/null 2>&1; then
        die "Latte-new image not found locally. Run: ./aws-benchmark.sh build"
    fi
    log "Local images verified"
}

###############################################################################
# Ship images and scripts to loader
###############################################################################
ship_images_to_loader() {
    local host="$LOADER_PUBLIC_IP"

    log "Shipping latte-alternator image to loader..."
    docker save latte-alternator | ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host" "sudo docker load"
    log "Latte image loaded on loader"

    log "Shipping latte-alternator-new image to loader..."
    docker save latte-alternator-new | ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host" "sudo docker load"
    log "Latte-new image loaded on loader"

    log "Shipping benchmark scripts to loader..."
    scp $SSH_OPTS -i "$KEY_FILE" \
        "$BENCHMARKS_DIR/run-latte-benchmark.sh" \
        "$BENCHMARKS_DIR/performance.rn" \
        "$BENCHMARKS_DIR/dynamodb.properties" \
        "$BENCHMARKS_DIR/AWSCredentials.properties" \
        "$BENCHMARKS_DIR/analyze_latte_results.py" \
        "$BENCHMARKS_DIR/analyze_scylla_metrics.py" \
        "ubuntu@$host:~/"
    log "Scripts shipped to loader"
}

###############################################################################
# Load data
###############################################################################
load_data() {
    local host="$LOADER_PUBLIC_IP"
    log "Loading $ROW_COUNT rows into Scylla..."

    remote "$host" bash -s <<LOAD_SCRIPT
set -euo pipefail
sudo docker run --rm --net host \
  --entrypoint latte-alternator \
  latte-alternator \
  schema performance.rn http://${SCYLLA_PRIVATE_IP}:8000 \
    -P "table=\"${TABLE}\""

sudo docker run --rm --net host \
  --entrypoint latte-alternator \
  latte-alternator \
  load performance.rn http://${SCYLLA_PRIVATE_IP}:8000 \
    -t 8 --concurrency 128 \
    -P "table=\"${TABLE}\"" \
    -P "row_count=${ROW_COUNT}" \
    -P "fieldcount=${FIELDCOUNT}" \
    -P "fieldlength=${FIELDLENGTH}" \
    -P 'requestdistribution="uniform"'
LOAD_SCRIPT
    log "Data loaded"
}

###############################################################################
# Monitoring — simplified: mpstat per host + Prometheus scrape on Scylla
###############################################################################
start_monitoring() {
    local tag="$1"
    log "Starting monitoring: $tag"

    # mpstat on both hosts (single collector per host)
    for host in "$SCYLLA_PUBLIC_IP" "$LOADER_PUBLIC_IP"; do
        remote "$host" bash -s <<MON
set -eu
mkdir -p ~/monitor
nohup mpstat -P ALL ${MONITOR_INTERVAL} > ~/monitor/${tag}_cpu.log 2>&1 &
echo \$! > ~/monitor/${tag}_pids
MON
    done

    # Prometheus scrape on Scylla node (always-on)
    remote "$SCYLLA_PUBLIC_IP" bash -s <<PROM
set -eu
mkdir -p ~/monitor
nohup bash -c 'while true; do echo "---TIMESTAMP \$(date +%s)---"; curl -s http://localhost:9180/metrics 2>/dev/null || true; sleep ${MONITOR_INTERVAL}; done' > ~/monitor/${tag}_prometheus.log 2>&1 &
echo \$! >> ~/monitor/${tag}_pids
PROM
}

stop_monitoring() {
    local tag="$1"
    for host in "$SCYLLA_PUBLIC_IP" "$LOADER_PUBLIC_IP"; do
        remote "$host" bash -s <<STOP
set -eu
pidfile=~/monitor/${tag}_pids
if [ -f "\$pidfile" ]; then
    while read -r pid; do
        kill "\$pid" 2>/dev/null || true
    done < "\$pidfile"
    rm -f "\$pidfile"
fi
STOP
    done
}

collect_monitoring() {
    local tag="$1"
    local dest="$2"
    mkdir -p "$dest"

    # Scylla node: cpu + prometheus
    scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$SCYLLA_PUBLIC_IP:~/monitor/${tag}_cpu.log" "$dest/scylla_cpu.log" 2>/dev/null || true
    scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$SCYLLA_PUBLIC_IP:~/monitor/${tag}_prometheus.log" "$dest/scylla_prometheus.log" 2>/dev/null || true

    # Loader node: cpu only
    scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$LOADER_PUBLIC_IP:~/monitor/${tag}_cpu.log" "$dest/loader_cpu.log" 2>/dev/null || true
}

###############################################################################
# Run a single benchmark pass
###############################################################################
run_one_pass() {
    local tool="$1"
    local inflight="$2"
    local run_tag="$3"
    local out_dir="$4"
    local host="$LOADER_PUBLIC_IP"

    mkdir -p "$out_dir"
    start_monitoring "$run_tag"

    if [[ "$tool" == "latte" ]]; then
        local params
        params=$(compute_latte_params "$inflight")
        local threads=${params%% *}
        local concurrency=${params##* }
        log "  Latte: inflight=$inflight (${threads}t x ${concurrency}c) duration=${RUN_DURATION_SEC}s warmup=${WARMUP_SEC}s rate=${RATE:-unlimited}"
        remote "$host" bash -s <<LATTE_RUN
set -euo pipefail
mkdir -p ~/output
sudo docker run --rm --net host \
  -v "\$HOME/output:/output" \
  -e ALT_ENDPOINT=http://${SCYLLA_PRIVATE_IP}:8000 \
  -e TABLE=${TABLE} \
  -e ROW_COUNT=${ROW_COUNT} \
  -e THREADS=${threads} \
  -e CONCURRENCY=${concurrency} \
  -e FIELDCOUNT=${FIELDCOUNT} \
  -e FIELDLENGTH=${FIELDLENGTH} \
  -e READ_PROPORTION=${READ_PROPORTION} \
  -e UPDATE_PROPORTION=${UPDATE_PROPORTION} \
  -e RUN_DURATION_SEC=${RUN_DURATION_SEC} \
  -e WARMUP_SEC=${WARMUP_SEC} \
  -e RATE=${RATE} \
  -e OUTDIR=/output \
  -e LATTE_WORKLOAD=performance.rn \
  latte-alternator
LATTE_RUN
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/latte_1.log" "$out_dir/" 2>/dev/null || true
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/latte_1.json" "$out_dir/" 2>/dev/null || true
        remote "$host" "rm -rf ~/output/*"

    elif [[ "$tool" == "latte-new-rr" || "$tool" == "latte-new-affinity" ]]; then
        local params
        params=$(compute_latte_params "$inflight")
        local threads=${params%% *}
        local concurrency=${params##* }
        local lb_policy="round-robin"
        [[ "$tool" == "latte-new-affinity" ]] && lb_policy="affinity-key-routing"

        log "  Latte-New ($tool): inflight=$inflight (${threads}t x ${concurrency}c) policy=$lb_policy duration=${RUN_DURATION_SEC}s warmup=${WARMUP_SEC}s rate=${RATE:-unlimited}"
        remote "$host" bash -s <<LATTE_NEW_RUN
set -euo pipefail
mkdir -p ~/output
sudo docker run --rm --net host \
  -v "\$HOME/output:/output" \
  -e ALT_ENDPOINT=http://${SCYLLA_PRIVATE_IP}:8000 \
  -e TABLE=${TABLE} \
  -e ROW_COUNT=${ROW_COUNT} \
  -e THREADS=${threads} \
  -e CONCURRENCY=${concurrency} \
  -e FIELDCOUNT=${FIELDCOUNT} \
  -e FIELDLENGTH=${FIELDLENGTH} \
  -e READ_PROPORTION=${READ_PROPORTION} \
  -e UPDATE_PROPORTION=${UPDATE_PROPORTION} \
  -e RUN_DURATION_SEC=${RUN_DURATION_SEC} \
  -e WARMUP_SEC=${WARMUP_SEC} \
  -e RATE=${RATE} \
  -e OUTDIR=/output \
  -e LATTE_WORKLOAD=performance.rn \
  -e LATTE_BINARY=latte-alternator-new \
  -e LB_POLICY="$lb_policy" \
  -e REQUEST_COMPRESSION="off" \
  latte-alternator-new
LATTE_NEW_RUN
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/latte_1.log" "$out_dir/" 2>/dev/null || true
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/latte_1.json" "$out_dir/" 2>/dev/null || true
        remote "$host" "rm -rf ~/output/*"
    fi

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
#   loader_cpu_pct,scylla_cpu_pct,
#   scylla_ops_per_sec,scylla_p99_ms,scylla_reactor_util_pct
###############################################################################
CSV_HEADER="tool,inflight,rate,rep,ops_per_sec,get_cycle_mean_ms,get_cycle_p99_ms,upd_cycle_mean_ms,upd_cycle_p99_ms,agg_request_mean_ms,agg_request_p99_ms,loader_cpu_pct,scylla_cpu_pct,scylla_ops_per_sec,scylla_p99_ms,scylla_reactor_util_pct"

# Extract average CPU% from mpstat -P ALL log (the "all" row)
parse_cpu_pct() {
    local logfile="$1"
    if [[ -f "$logfile" ]]; then
        # mpstat -P ALL: lines with " all " contain aggregate; %idle is last column
        awk '/^ *[0-9].*all/ { idle+=$NF; n++ } END { if(n>0) printf "%.1f", 100 - idle/n; else print "0" }' "$logfile" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

parse_result_line() {
    local tool="$1"
    local inflight="$2"
    local rate_val="$3"
    local rep="$4"
    local out_dir="$5"

    local rate_str="${rate_val:-unlimited}"
    local loader_cpu scylla_cpu
    loader_cpu=$(parse_cpu_pct "$out_dir/loader_cpu.log")
    scylla_cpu=$(parse_cpu_pct "$out_dir/scylla_cpu.log")

    # Scylla server-side metrics from Prometheus
    local scylla_ops="0" scylla_p99="0" scylla_reactor="0"
    if [[ -f "$out_dir/scylla_prometheus.log" ]]; then
        local prom_json
        prom_json=$(python3 "$BENCHMARKS_DIR/analyze_scylla_metrics.py" "$out_dir/scylla_prometheus.log" 2>/dev/null || echo "{}")
        scylla_ops=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ops_per_sec','0'))" 2>/dev/null || echo "0")
        scylla_p99=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('p99_ms','0'))" 2>/dev/null || echo "0")
        scylla_reactor=$(echo "$prom_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('reactor_util_pct','0'))" 2>/dev/null || echo "0")
    fi

    if [[ "$tool" == latte* ]]; then
        local jsonfile="$out_dir/latte_1.json"
        if [[ -f "$jsonfile" ]]; then
            python3 "$BENCHMARKS_DIR/analyze_latte_results.py" "$out_dir" \
                --csv-prefix "${tool},$inflight,$rate_str,$rep" \
                --csv-suffix "$loader_cpu,$scylla_cpu,$scylla_ops,$scylla_p99,$scylla_reactor"
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

    load_data

    for inflight in $INFLIGHT_LIST; do
        for ((rep=1; rep<=REPETITIONS; rep++)); do
            # Alternate tool order per rep to reduce ordering bias
            local tools
            if (( rep % 2 == 1 )); then
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
    log "=== Local build phase (no EC2 cost) ==="
    build_local_images
    log "Build complete. Next: ./aws-benchmark.sh provision"
}

cmd_provision() {
    preflight
    verify_local_images

    find_tagged_instances
    if instances_exist; then
        log "Existing instances found:"
        log "  Scylla: $SCYLLA_INSTANCE_ID ($SCYLLA_PUBLIC_IP / $SCYLLA_PRIVATE_IP)"
        log "  Loader: $LOADER_INSTANCE_ID ($LOADER_PUBLIC_IP)"
        log "Reusing existing instances. Use 'teardown' first to start fresh."
        ship_images_to_loader
        return 0
    fi

    ensure_key_pair
    find_vpc_and_subnet
    ensure_security_group
    find_ami

    log "Launching Scylla instance ($SCYLLA_INSTANCE_TYPE)..."
    SCYLLA_INSTANCE_ID=$(launch_instance "$SCYLLA_INSTANCE_TYPE" "latte-bench-scylla")
    log "Scylla instance: $SCYLLA_INSTANCE_ID"

    log "Launching Loader instance ($LOADER_INSTANCE_TYPE)..."
    LOADER_INSTANCE_ID=$(launch_instance "$LOADER_INSTANCE_TYPE" "latte-bench-loader")
    log "Loader instance: $LOADER_INSTANCE_ID"

    log "Waiting for instances to be running..."
    aws ec2 wait instance-running --region "$REGION" \
        --instance-ids "$SCYLLA_INSTANCE_ID" "$LOADER_INSTANCE_ID"

    SCYLLA_PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$SCYLLA_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    SCYLLA_PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$SCYLLA_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
    LOADER_PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$LOADER_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    log "Scylla: public=$SCYLLA_PUBLIC_IP private=$SCYLLA_PRIVATE_IP"
    log "Loader: public=$LOADER_PUBLIC_IP"

    wait_for_ssh "$SCYLLA_PUBLIC_IP" &
    wait_for_ssh "$LOADER_PUBLIC_IP" &
    wait

    setup_scylla
    setup_loader
    ship_images_to_loader

    log "Provision complete. Next: ./aws-benchmark.sh run smoke"
}

cmd_teardown() {
    find_tagged_instances
    if ! instances_exist; then
        log "No active benchmark instances found."
        return 0
    fi

    log "Terminating instances..."
    local ids=()
    [[ -n "$SCYLLA_INSTANCE_ID" ]] && ids+=("$SCYLLA_INSTANCE_ID")
    [[ -n "$LOADER_INSTANCE_ID" ]] && ids+=("$LOADER_INSTANCE_ID")
    aws ec2 terminate-instances --region "$REGION" --instance-ids "${ids[@]}" >/dev/null 2>&1 || true
    log "Waiting for termination..."
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "${ids[@]}" 2>/dev/null || true
    log "Teardown complete."
}

cmd_run() {
    local phase="${1:-}"
    [[ -z "$phase" ]] && die "Usage: ./aws-benchmark.sh run {smoke|latency|throughput}"

    find_tagged_instances
    if ! instances_exist; then
        die "No active instances. Run './aws-benchmark.sh provision' first."
    fi
    log "Using instances: Scylla=$SCYLLA_PUBLIC_IP Loader=$LOADER_PUBLIC_IP"

    case "$phase" in
        smoke)
            ROW_COUNT=100000
            RUN_DURATION_SEC=60
            WARMUP_SEC=0
            REPETITIONS=1
            RATE=5000
            INFLIGHT_LIST="32"
            run_phase "smoke"
            ;;
        latency)
            ROW_COUNT=1000000
            RUN_DURATION_SEC=120
            WARMUP_SEC=30
            REPETITIONS=2
            RATE=5000
            INFLIGHT_LIST="32"
            run_phase "latency"
            ;;
        throughput)
            ROW_COUNT=1000000
            RUN_DURATION_SEC=120
            WARMUP_SEC=30
            REPETITIONS=2
            RATE=""
            INFLIGHT_LIST="128 256"
            run_phase "throughput"
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
            echo "  1. ./aws-benchmark.sh build       # Local: docker build + pull"
            echo "  2. ./aws-benchmark.sh provision    # EC2: launch + setup"
            echo "  3. ./aws-benchmark.sh run smoke    # Validate pipeline + parsers"
            echo "  4. ./aws-benchmark.sh run latency  # Rate-limited comparison"
            echo "  5. ./aws-benchmark.sh run throughput # Saturated comparison"
            echo "  6. ./aws-benchmark.sh report       # Show all results"
            echo "  7. ./aws-benchmark.sh teardown     # Destroy instances"
            exit 1
            ;;
    esac
}

main "$@"
