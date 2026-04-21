#!/usr/bin/env bash
#
# aws-benchmark.sh — Fair Latte vs YCSB comparison on Alternator (ScyllaDB).
#
# Usage:
#   ./aws-benchmark.sh build                     # Local: docker build latte + pull YCSB
#   ./aws-benchmark.sh provision                 # EC2: launch instances + ship images
#   ./aws-benchmark.sh teardown                  # Destroy tagged instances
#   ./aws-benchmark.sh run smoke                 # Quick pipeline test (20s, 1 rep)
#   ./aws-benchmark.sh run quick-latency         # 30s, 1 rep, rate-limited
#   ./aws-benchmark.sh run quick-throughput      # 30s, 1 rep, sweep {32,128}
#   ./aws-benchmark.sh run medium-latency        # 60s, 2 reps, rate-limited
#   ./aws-benchmark.sh run medium-throughput     # 60s, 2 reps, sweep {32,64,128,256}
#   ./aws-benchmark.sh run final                 # 120s, 3 reps (fresh provision, larger instances)
#   ./aws-benchmark.sh run custom                # Use env vars directly
#   ./aws-benchmark.sh report                    # Aggregate results into summary
#
set -euo pipefail

###############################################################################
# Configuration — override any of these via environment variables
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

# Instance types (defaults for smoke/quick/medium phases)
SCYLLA_INSTANCE_TYPE="${SCYLLA_INSTANCE_TYPE:-i3.xlarge}"
LOADER_INSTANCE_TYPE="${LOADER_INSTANCE_TYPE:-c5.2xlarge}"

# Scylla
SCYLLA_IMAGE="${SCYLLA_IMAGE:-scylladb/scylla-nightly:2026.1.0-dev-0.20251003.20aeed160740-x86_64}"
ALTERNATOR_WRITE_ISOLATION="${ALTERNATOR_WRITE_ISOLATION:-only_rmw_uses_lwt}"

# YCSB image (prebuilt from scylladb)
YCSB_DOCKER_IMAGE="${YCSB_DOCKER_IMAGE:-scylladb/ycsb:1.3.0}"

# Benchmark parameters (overridden per phase)
TABLE="${TABLE:-latte_performance}"
ROW_COUNT="${ROW_COUNT:-100000}"
FIELDCOUNT="${FIELDCOUNT:-10}"
FIELDLENGTH="${FIELDLENGTH:-512}"
READ_PROPORTION="${READ_PROPORTION:-0.5}"
UPDATE_PROPORTION="${UPDATE_PROPORTION:-0.5}"
RUN_DURATION_SEC="${RUN_DURATION_SEC:-30}"
WARMUP_SEC="${WARMUP_SEC:-0}"
REPETITIONS="${REPETITIONS:-1}"
RATE="${RATE:-}"
INFLIGHT_LIST="${INFLIGHT_LIST:-64}"
# Default thread/concurrency split for Latte: we pick threads to balance.
# YCSB: threads = inflight (1 in-flight per thread, synchronous).
# Latte: threads × concurrency = inflight (async). We pick threads=min(inflight, 8).
LATTE_THREADS_HINT="${LATTE_THREADS_HINT:-8}"

# Local paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARKS_DIR="${BENCHMARKS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/benchmark-results}"

# Cleanup control
CLEANUP_AWS_RESOURCES="${CLEANUP_AWS_RESOURCES:-false}"

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

# Compute Latte threads and per-thread concurrency for a given total in-flight.
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
# Tag-based instance discovery (for keep-alive / reuse)
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
# Ensure SSH key pair exists
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
# Find VPC and subnet
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
# Ensure security group exists
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
# Find AMI
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
# Launch an EC2 instance with fallback from i3 to i4i
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

    # Fallback: i3 -> i4i
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
# Build local Docker images (no EC2 contact)
###############################################################################
build_local_images() {
    # Verify Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running. Start Docker first."
    fi

    # Build latte image (relies on layer cache for fast rebuilds)
    log "Building latte-alternator Docker image locally..."
    docker build -t latte-alternator -f "$BENCHMARKS_DIR/Dockerfile.latte" "$BENCHMARKS_DIR"
    log "Latte image built"

    # Pull YCSB image locally (validates tag, ensures local copy)
    log "Pulling $YCSB_DOCKER_IMAGE locally..."
    docker pull "$YCSB_DOCKER_IMAGE"
    log "YCSB image pulled"

    # Summary
    log "Local images ready:"
    docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}  ({{.CreatedSince}})' latte-alternator
    docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}  ({{.CreatedSince}})' "$YCSB_DOCKER_IMAGE"
}

###############################################################################
# Verify local images exist (pre-flight for provision)
###############################################################################
verify_local_images() {
    if ! docker image inspect latte-alternator >/dev/null 2>&1; then
        die "Latte image not found locally. Run: ./aws-benchmark.sh build"
    fi
    if ! docker image inspect "$YCSB_DOCKER_IMAGE" >/dev/null 2>&1; then
        die "YCSB image ($YCSB_DOCKER_IMAGE) not found locally. Run: ./aws-benchmark.sh build"
    fi
    log "Local images verified"
}

###############################################################################
# Ship images and scripts to loader (EC2 only)
###############################################################################
ship_images_to_loader() {
    local host="$LOADER_PUBLIC_IP"

    # Ship latte image via docker save | ssh docker load
    log "Shipping latte-alternator image to loader..."
    docker save latte-alternator | ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host" "sudo docker load"
    log "Latte image loaded on loader"

    # Pull YCSB prebuilt image on loader (faster than uploading)
    log "Pulling $YCSB_DOCKER_IMAGE on loader..."
    remote "$host" "sudo docker pull $YCSB_DOCKER_IMAGE"
    log "YCSB image ready on loader"

    # Ship run scripts and workload files to loader
    log "Shipping benchmark scripts to loader..."
    scp $SSH_OPTS -i "$KEY_FILE" \
        "$BENCHMARKS_DIR/run-latte-benchmark.sh" \
        "$BENCHMARKS_DIR/run-ycsb-benchmark.sh" \
        "$BENCHMARKS_DIR/performance.rn" \
        "$BENCHMARKS_DIR/dynamodb.properties" \
        "$BENCHMARKS_DIR/AWSCredentials.properties" \
        "$BENCHMARKS_DIR/analyze_latte_results.py" \
        "$BENCHMARKS_DIR/analyze_ycsb_results.py" \
        "ubuntu@$host:~/"
    log "Scripts shipped to loader"
}

###############################################################################
# Load data (once per provision, or when ROW_COUNT changes)
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
    -P 'table="${TABLE}"'

sudo docker run --rm --net host \
  --entrypoint latte-alternator \
  latte-alternator \
  load performance.rn http://${SCYLLA_PRIVATE_IP}:8000 \
    -t 8 --concurrency 128 \
    -P 'table="${TABLE}"' \
    -P "row_count=${ROW_COUNT}" \
    -P "fieldcount=${FIELDCOUNT}" \
    -P "fieldlength=${FIELDLENGTH}" \
    -P 'requestdistribution="uniform"'
LOAD_SCRIPT
    log "Data loaded"
}

###############################################################################
# Monitoring
###############################################################################
MONITOR_INTERVAL=5

start_monitoring() {
    local tag="$1"
    log "Starting monitoring: $tag"
    for host in "$SCYLLA_PUBLIC_IP" "$LOADER_PUBLIC_IP"; do
        remote "$host" bash -s <<MON
set -eu
mkdir -p ~/monitor
nohup mpstat ${MONITOR_INTERVAL} > ~/monitor/${tag}_cpu.log 2>&1 &
echo \$! > ~/monitor/${tag}_cpu.pid
nohup pidstat -u ${MONITOR_INTERVAL} > ~/monitor/${tag}_pidstat.log 2>&1 &
echo \$! > ~/monitor/${tag}_pidstat.pid
MON
    done

    # Optional: scrape Alternator Prometheus metrics on Scylla node
    if [[ "${SCRAPE_ALTERNATOR_METRICS:-}" == "1" ]]; then
        log "Starting Alternator metrics scrape on Scylla node"
        remote "$SCYLLA_PUBLIC_IP" bash -s <<ALTMON
set -eu
mkdir -p ~/monitor
nohup bash -c 'while true; do echo "---TIMESTAMP \$(date +%s)---"; curl -s http://localhost:9180/metrics 2>/dev/null || true; sleep ${MONITOR_INTERVAL}; done' > ~/monitor/${tag}_alt_metrics.log 2>&1 &
echo \$! > ~/monitor/${tag}_alt_metrics.pid
ALTMON
    fi

    # Optional: scrape network stats on Scylla node
    if [[ "${SCRAPE_NETSTAT:-}" == "1" ]]; then
        log "Starting netstat scrape on Scylla node"
        remote "$SCYLLA_PUBLIC_IP" bash -s <<NETMON
set -eu
mkdir -p ~/monitor
nohup bash -c 'while true; do echo "---TIMESTAMP \$(date +%s)---"; ss -tin 2>/dev/null || true; nstat -az 2>/dev/null || true; sleep ${MONITOR_INTERVAL}; done' > ~/monitor/${tag}_netstat.log 2>&1 &
echo \$! > ~/monitor/${tag}_netstat.pid
NETMON
    fi
}

stop_monitoring() {
    local tag="$1"
    for host in "$SCYLLA_PUBLIC_IP" "$LOADER_PUBLIC_IP"; do
        remote "$host" bash -s <<STOP
set -eu
cd ~/monitor 2>/dev/null || exit 0
for pidfile in ${tag}_*.pid; do
    [ -f "\$pidfile" ] && kill \$(cat "\$pidfile") 2>/dev/null || true
    rm -f "\$pidfile"
done
STOP
    done
}

collect_monitoring() {
    local tag="$1"
    local dest="$2"
    mkdir -p "$dest"
    scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$SCYLLA_PUBLIC_IP:~/monitor/${tag}_*.log" "$dest/" 2>/dev/null || true
    for f in "$dest/${tag}_cpu.log" "$dest/${tag}_pidstat.log"; do
        [ -f "$f" ] && mv "$f" "$dest/scylla_$(basename "$f" | sed "s/${tag}_//")" 2>/dev/null || true
    done
    # Rename optional Scylla-side logs (alt_metrics, netstat)
    for suffix in alt_metrics netstat; do
        local src="$dest/${tag}_${suffix}.log"
        [ -f "$src" ] && mv "$src" "$dest/scylla_${suffix}.log" 2>/dev/null || true
    done
    scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$LOADER_PUBLIC_IP:~/monitor/${tag}_*.log" "$dest/" 2>/dev/null || true
    for f in "$dest/${tag}_cpu.log" "$dest/${tag}_pidstat.log"; do
        [ -f "$f" ] && mv "$f" "$dest/loader_$(basename "$f" | sed "s/${tag}_//")" 2>/dev/null || true
    done
}

###############################################################################
# Run a single benchmark pass
# Usage: run_one_pass <tool> <inflight> <run_tag> <out_dir>
###############################################################################
run_one_pass() {
    local tool="$1"
    local inflight="$2"
    local run_tag="$3"
    local out_dir="$4"
    local host="$LOADER_PUBLIC_IP"

    mkdir -p "$out_dir"
    start_monitoring "$run_tag"

    if [[ "$tool" == "ycsb" ]]; then
        log "  YCSB: inflight=$inflight duration=${RUN_DURATION_SEC}s warmup=${WARMUP_SEC}s rate=${RATE:-unlimited}"
        local cpuset_flag=""
        [[ -n "${LOADER_CPUSET:-}" ]] && cpuset_flag="--cpuset-cpus=${LOADER_CPUSET}" && log "  YCSB: cpuset=${LOADER_CPUSET}"
        remote "$host" bash -s <<YCSB_RUN
set -euo pipefail
mkdir -p ~/output
sudo docker run --rm --net host ${cpuset_flag} \
  -v "\$HOME/run-ycsb-benchmark.sh:/run-benchmark.sh:ro" \
  -v "\$HOME/output:/output" \
  -v "\$HOME/dynamodb.properties:/dynamodb.properties:ro" \
  -v "\$HOME/AWSCredentials.properties:/AWSCredentials.properties:ro" \
  -v "\$HOME/performance.rn:/performance.rn:ro" \
  -e ALT_ENDPOINT=http://${SCYLLA_PRIVATE_IP}:8000 \
  -e TABLE=${TABLE} \
  -e ROW_COUNT=${ROW_COUNT} \
  -e YCSB_THREADS=${inflight} \
  -e FIELDCOUNT=${FIELDCOUNT} \
  -e FIELDLENGTH=${FIELDLENGTH} \
  -e READ_PROPORTION=${READ_PROPORTION} \
  -e UPDATE_PROPORTION=${UPDATE_PROPORTION} \
  -e RUN_DURATION_SEC=${RUN_DURATION_SEC} \
  -e WARMUP_SEC=${WARMUP_SEC} \
  -e RATE=${RATE} \
  -e YCSB_JAVA_OPTS="${YCSB_JAVA_OPTS:-}" \
  -e OUTDIR=/output \
  --entrypoint /bin/bash \
  ${YCSB_DOCKER_IMAGE} /run-benchmark.sh
YCSB_RUN
        # Collect results
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/ycsb_1.log" "$out_dir/" 2>/dev/null || true
        remote "$host" "rm -rf ~/output/*"

    elif [[ "$tool" == "latte" ]]; then
        local params
        params=$(compute_latte_params "$inflight")
        local threads=${params%% *}
        local concurrency=${params##* }
        log "  Latte: inflight=$inflight (${threads}t × ${concurrency}c) duration=${RUN_DURATION_SEC}s warmup=${WARMUP_SEC}s rate=${RATE:-unlimited}"
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
        # Collect results
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/latte_1.log" "$out_dir/" 2>/dev/null || true
        scp $SSH_OPTS -i "$KEY_FILE" "ubuntu@$host:~/output/latte_1.json" "$out_dir/" 2>/dev/null || true
        remote "$host" "rm -rf ~/output/*"
    fi

    stop_monitoring "$run_tag"
    collect_monitoring "$run_tag" "$out_dir"
}

###############################################################################
# Parse results from a single run and emit a CSV line
# Output: tool,inflight,rep,throughput,read_avg_ms,read_p95_ms,read_p99_ms,update_avg_ms,update_p95_ms,update_p99_ms
###############################################################################
parse_result_line() {
    local tool="$1"
    local inflight="$2"
    local rep="$3"
    local out_dir="$4"

    if [[ "$tool" == "ycsb" ]]; then
        local logfile="$out_dir/ycsb_1.log"
        if [[ -f "$logfile" ]]; then
            python3 -c "
import re, sys
t = open('$logfile').read()
def g(pat):
    m = re.search(pat, t)
    return float(m.group(1)) if m else 0
tp = g(r'\[OVERALL\], Throughput\(ops/sec\), ([0-9.]+)')
ra = g(r'\[READ\], AverageLatency\(us\), ([0-9.]+)') / 1000
r95 = g(r'\[READ\], 95thPercentileLatency\(us\), ([0-9.]+)') / 1000
r99 = g(r'\[READ\], 99thPercentileLatency\(us\), ([0-9.]+)') / 1000
ua = g(r'\[UPDATE\], AverageLatency\(us\), ([0-9.]+)') / 1000
u95 = g(r'\[UPDATE\], 95thPercentileLatency\(us\), ([0-9.]+)') / 1000
u99 = g(r'\[UPDATE\], 99thPercentileLatency\(us\), ([0-9.]+)') / 1000
print(f'ycsb,$inflight,$rep,{tp:.1f},{ra:.3f},{r95:.3f},{r99:.3f},{ua:.3f},{u95:.3f},{u99:.3f}')
"
        fi
    elif [[ "$tool" == "latte" ]]; then
        local jsonfile="$out_dir/latte_1.json"
        if [[ -f "$jsonfile" ]]; then
            python3 -c "
import json, sys
d = json.load(open('$jsonfile'))
r = d.get('result', {})
tp = r.get('cycle_throughput', {}).get('value', 0)
plist = d.get('percentiles', [])
p95i = plist.index(95.0) if 95.0 in plist else -1
p99i = plist.index(99.0) if 99.0 in plist else -1
fn = r.get('cycle_latency_by_fn', {})
def get_p(name, idx):
    ps = fn.get(name, {}).get('percentiles', [])
    return ps[idx].get('value', 0) if 0 <= idx < len(ps) else 0
def get_m(name):
    return fn.get(name, {}).get('mean', {}).get('value', 0)
ra = get_m('get'); r95 = get_p('get', p95i); r99 = get_p('get', p99i)
ua = get_m('update'); u95 = get_p('update', p95i); u99 = get_p('update', p99i)
print(f'latte,$inflight,$rep,{tp:.1f},{ra:.3f},{r95:.3f},{r99:.3f},{ua:.3f},{u95:.3f},{u99:.3f}')
"
        fi
    fi
}

###############################################################################
# Run a complete benchmark phase
# Loops over inflight × repetitions, alternating tool order.
###############################################################################
run_phase() {
    local phase_name="$1"
    local phase_dir="$RESULTS_DIR/$phase_name"
    mkdir -p "$phase_dir"

    local csv="$phase_dir/summary.csv"
    echo "tool,inflight,rep,throughput_ops,read_avg_ms,read_p95_ms,read_p99_ms,update_avg_ms,update_p95_ms,update_p99_ms" > "$csv"

    log "=== Phase: $phase_name ==="
    log "Duration: ${RUN_DURATION_SEC}s | Warmup: ${WARMUP_SEC}s | Rate: ${RATE:-unlimited}"
    log "Inflight: $INFLIGHT_LIST | Reps: $REPETITIONS | Rows: $ROW_COUNT"
    echo

    # Load data once for this phase
    load_data

    for inflight in $INFLIGHT_LIST; do
        for ((rep=1; rep<=REPETITIONS; rep++)); do
            # Alternate tool order: odd reps = YCSB first, even = Latte first
            local tools
            local tool_list="${TOOLS:-ycsb latte}"
            if (( rep % 2 == 1 )); then
                tools="$tool_list"
            else
                # Reverse the tool list for even reps
                tools=$(echo "$tool_list" | awk '{for(i=NF;i>=1;i--) printf "%s ", $i; print ""}')
            fi

            for tool in $tools; do
                local tag="${phase_name}_${tool}_inf${inflight}_r${rep}"
                local out_dir="$phase_dir/${tool}/inflight=${inflight}/rep${rep}"
                log "--- $tool | inflight=$inflight | rep=$rep ---"
                run_one_pass "$tool" "$inflight" "$tag" "$out_dir"

                # Parse and append to CSV immediately
                local line
                line=$(parse_result_line "$tool" "$inflight" "$rep" "$out_dir")
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
# BUILD command — local only, no EC2
###############################################################################
cmd_build() {
    log "=== Local build phase (no EC2 cost) ==="
    build_local_images
    log "Build complete. Next: ./aws-benchmark.sh provision"
}

###############################################################################
# PROVISION command
###############################################################################
cmd_provision() {
    preflight
    verify_local_images

    # Check if instances already exist
    find_tagged_instances
    if instances_exist; then
        log "Existing instances found:"
        log "  Scylla: $SCYLLA_INSTANCE_ID ($SCYLLA_PUBLIC_IP / $SCYLLA_PRIVATE_IP)"
        log "  Loader: $LOADER_INSTANCE_ID ($LOADER_PUBLIC_IP)"
        log "Reusing existing instances. Use 'teardown' first to start fresh."

        # Re-ship images and scripts (ensures edits propagate)
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

###############################################################################
# TEARDOWN command
###############################################################################
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

    if [[ "$CLEANUP_AWS_RESOURCES" == "true" ]]; then
        find_vpc_and_subnet 2>/dev/null || true
        if [[ -n "${SG_ID:-}" ]]; then
            log "Deleting security group $SG_NAME"
            aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || true
        fi
        if [[ -f "$KEY_FILE" ]]; then
            log "Deleting key pair $KEY_NAME"
            aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" 2>/dev/null || true
            rm -f "$KEY_FILE"
        fi
    fi

    log "Teardown complete."
}

###############################################################################
# RUN command — executes a named phase
###############################################################################
cmd_run() {
    local phase="${1:-}"
    [[ -z "$phase" ]] && die "Usage: $0 run <phase>"

    # Ensure instances are available
    find_tagged_instances
    if ! instances_exist; then
        die "No active instances. Run './aws-benchmark.sh provision' first."
    fi
    log "Using instances: Scylla=$SCYLLA_PUBLIC_IP Loader=$LOADER_PUBLIC_IP"

    case "$phase" in
        smoke)
            ROW_COUNT=100000
            RUN_DURATION_SEC=20
            WARMUP_SEC=0
            REPETITIONS=1
            RATE=""
            INFLIGHT_LIST="64"
            run_phase "smoke"
            ;;
        quick-latency)
            ROW_COUNT=100000
            RUN_DURATION_SEC=30
            WARMUP_SEC=0
            REPETITIONS=1
            RATE=5000
            INFLIGHT_LIST="32"
            run_phase "quick-latency"
            ;;
        quick-throughput)
            ROW_COUNT=100000
            RUN_DURATION_SEC=30
            WARMUP_SEC=0
            REPETITIONS=1
            RATE=""
            INFLIGHT_LIST="32 128"
            run_phase "quick-throughput"
            ;;
        medium-latency)
            ROW_COUNT=1000000
            RUN_DURATION_SEC=60
            WARMUP_SEC=30
            REPETITIONS=2
            RATE=5000
            INFLIGHT_LIST="32"
            run_phase "medium-latency"
            ;;
        medium-throughput)
            ROW_COUNT=1000000
            RUN_DURATION_SEC=60
            WARMUP_SEC=30
            REPETITIONS=2
            RATE=""
            INFLIGHT_LIST="32 64 128 256"
            run_phase "medium-throughput"
            ;;
        final)
            ROW_COUNT=5000000
            RUN_DURATION_SEC=60
            WARMUP_SEC=30
            REPETITIONS=2

            # Latte-only throughput sweep (find new Scylla ceiling)
            TOOLS="latte"
            RATE=""
            INFLIGHT_LIST="64 128 256 512"
            run_phase "final-latte-throughput"

            # YCSB-only throughput sweep (validate ceiling on bigger loader)
            TOOLS="ycsb"
            RATE=""
            INFLIGHT_LIST="128 256"
            run_phase "final-ycsb-throughput"

            # Latency block — both tools at matched rate
            TOOLS="ycsb latte"
            RATE=5000
            INFLIGHT_LIST="32"
            run_phase "final-latency"
            ;;
        custom)
            run_phase "custom-$(date +%Y%m%d-%H%M%S)"
            ;;
        *)
            die "Unknown phase: $phase. Valid: smoke, quick-latency, quick-throughput, medium-latency, medium-throughput, final, custom"
            ;;
    esac
}

###############################################################################
# REPORT command — aggregate CSV summaries
###############################################################################
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
            echo "Phases: smoke, quick-latency, quick-throughput, medium-latency, medium-throughput, final, custom"
            echo
            echo "Workflow:"
            echo "  1. ./aws-benchmark.sh build            # Local: docker build + pull (no EC2 cost)"
            echo "  2. ./aws-benchmark.sh provision         # EC2: launch instances + ship images"
            echo "  3. ./aws-benchmark.sh run smoke         # Verify pipeline"
            echo "  4. ./aws-benchmark.sh run quick-latency"
            echo "  5. ./aws-benchmark.sh run quick-throughput"
            echo "  6. ... iterate medium-* ..."
            echo "  7. ./aws-benchmark.sh teardown          # Destroy instances"
            echo "  8. (Optional: re-provision larger)  # For final phase"
            echo "  9. ./aws-benchmark.sh run final"
            echo " 10. ./aws-benchmark.sh report"
            echo " 11. ./aws-benchmark.sh teardown"
            exit 1
            ;;
    esac
}

main "$@"
