#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# MultiKueue Demo — Shows how MultiKueue distributes training jobs across
# clusters based on available GPU capacity.
#
# --target is the region whose VIP receives the initial load. That region gets
# 2 training jobs (filling GPU capacity). The spillover region gets 1 training
# job (leaving 2 GPUs free). When GCLB spills traffic to the spillover region,
# HPA scales out, Kueue preempts the training job, and MultiKueue reschedules
# it to the target region (which has room because its HPA doesn't scale).
#
# Usage:
#   ./demo-multikueue.sh --target east1             # Interactive, load enters east1
#   ./demo-multikueue.sh --target west3             # Interactive, load enters west3
#   ./demo-multikueue.sh --target east1 --auto      # Automated with pauses
# ─────────────────────────────────────────────────────────────────────────────
set -e

# Fix for terminals not recognized on remote hosts (e.g. Ghostty)
case "$TERM" in xterm-ghostty|*-unknown) export TERM=xterm-256color ;; esac

# Safety trap: always restore ClusterQueue quotas on exit/interrupt
trap 'kubectl patch clusterqueue gpu-cluster-queue --context worker-east1 --type=merge -p "{\"spec\":{\"resourceGroups\":[{\"coveredResources\":[\"nvidia.com/gpu\"],\"flavors\":[{\"name\":\"rtx-pro-6000\",\"resources\":[{\"name\":\"nvidia.com/gpu\",\"nominalQuota\":8}]}]}]}}" 2>/dev/null
kubectl patch clusterqueue gpu-cluster-queue --context worker-west3 --type=merge -p "{\"spec\":{\"resourceGroups\":[{\"coveredResources\":[\"nvidia.com/gpu\"],\"flavors\":[{\"name\":\"rtx-pro-6000\",\"resources\":[{\"name\":\"nvidia.com/gpu\",\"nominalQuota\":8}]}]}]}}" 2>/dev/null' EXIT INT TERM

AUTO=false
TARGET=""
RUN_LOAD=false

for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=true ;;
    --load) RUN_LOAD=true ;;
    --target) :;; # next arg is the value
    east1|--target=east1) TARGET="east1" ;;
    west3|--target=west3) TARGET="west3" ;;
  esac
done

# Handle --target <value> form
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Usage: $0 --target <east1|west3> [--auto] [--load]"
  echo ""
  echo "  --target east1   Load enters east1 VIP; 2 jobs on east1, 1 on west3"
  echo "  --target west3   Load enters west3 VIP; 2 jobs on west3, 1 on east1"
  echo "  --auto           Automated mode with pauses (for recording)"
  echo "  --load           After scheduling jobs, start the load test (load mode, no dashboard)"
  exit 1
fi

if [ "$TARGET" = "east1" ]; then
  TARGET_CTX="worker-east1"
  TARGET_LABEL="east1"
  TARGET_COLOR='\033[0;31m'
  OTHER_CTX="worker-west3"
  OTHER_LABEL="west3"
  OTHER_COLOR='\033[0;36m'
else
  TARGET_CTX="worker-west3"
  TARGET_LABEL="west3"
  TARGET_COLOR='\033[0;36m'
  OTHER_CTX="worker-east1"
  OTHER_LABEL="east1"
  OTHER_COLOR='\033[0;31m'
fi

# Discover VIP for target region from the gateway
# Gateway spec addresses contain region in type, status addresses have IPs in same order
VIP=$(kubectl get gateway cross-region-gateway -n gateway-system --context mgmt -o json 2>/dev/null | python3 -c "
import sys, json
gw = json.load(sys.stdin)
spec = gw.get('spec',{}).get('addresses',[])
status = gw.get('status',{}).get('addresses',[])
for i, sa in enumerate(spec):
    region = sa.get('type','').rsplit('/',1)[-1]
    if region == 'us-${TARGET_LABEL}' and i < len(status):
        print(status[i].get('value',''))
        break
" 2>/dev/null)

if [ -z "$VIP" ]; then
  echo "ERROR: Cannot discover VIP for us-${TARGET_LABEL} from gateway. Check mgmt cluster connectivity."
  exit 1
fi

LOAD_CMD="python3 load_test.py --target-cluster $TARGET --concurrency 1500 --max-tokens 512"

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

pause() {
  if $AUTO; then
    sleep "${1:-3}"
  else
    echo -e "${DIM}  ↵ Press Enter to continue...${NC}"
    read -r
  fi
}

narrate() {
  echo ""
  echo -e "${BOLD}${CYAN}▸ $1${NC}"
  echo ""
}

show_gpu_state() {
  for ctx in worker-east1 worker-west3; do
    label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
    inf=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    train=$(kubectl get pods -n training-jobs --context $ctx --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    free=$((8 - inf - train))
    [ $free -lt 0 ] && free=0
    bar=""
    for i in $(seq 1 $inf); do bar="${bar}${CYAN}█${NC}"; done
    for i in $(seq 1 $train); do bar="${bar}${MAGENTA}█${NC}"; done
    for i in $(seq 1 $free); do bar="${bar}░"; done
    marker=""
    [ "$label" = "$TARGET_LABEL" ] && marker=" ${YELLOW}← load enters here (HPA pinned)${NC}"
    [ "$label" = "$OTHER_LABEL" ] && [ "$free" -gt 0 ] && marker=" ${GREEN}← spillover (HPA scales, preempts)${NC}"
    echo -e "  ${BOLD}$label${NC}  [${bar}]  ${CYAN}${inf}i${NC} ${MAGENTA}${train}t${NC} ${DIM}${free} free${NC}${marker}"
  done
  echo -e "  ${DIM}Legend: ${CYAN}█${NC}${DIM}=inference ${MAGENTA}█${NC}${DIM}=training ░=free${NC}"
}

show_mgmt_workloads() {
  echo -e "  ${DIM}── mgmt cluster workloads ──${NC}"
  kubectl get workloads -n training-jobs --context mgmt --no-headers 2>/dev/null | while read name queue reserved admitted rest; do
    short=$(echo "$name" | sed 's/jobset-//' | sed 's/-[a-f0-9]*$//')
    echo -e "  ${MAGENTA}$short${NC}  admitted=${GREEN}$admitted${NC}"
  done
  [ "$(kubectl get workloads -n training-jobs --context mgmt --no-headers 2>/dev/null | wc -l)" -eq 0 ] && echo -e "  ${DIM}(none)${NC}"
}

show_worker_training() {
  for ctx in worker-east1 worker-west3; do
    label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
    pods=$(kubectl get pods -n training-jobs --context $ctx --field-selector=status.phase=Running --no-headers 2>/dev/null || true)
    count=$(echo "$pods" | grep -c "Running" || true)
    if [ "$count" -gt 0 ]; then
      echo -e "  ${BOLD}$label${NC}: $count training pods"
      echo "$pods" | awk -v m="${MAGENTA}" -v nc="${NC}" '{printf "    %s%s%s %s\n", m, $1, nc, $3}'
    else
      echo -e "  ${BOLD}$label${NC}: ${DIM}no training pods${NC}"
    fi
  done
}

submit_job() {
  local job_name=$1
  local job_num=$2

  cat <<EOF | kubectl apply --context mgmt -f - 2>&1 | grep -v "^$"
apiVersion: jobset.x-k8s.io/v1alpha2
kind: JobSet
metadata:
  name: $job_name
  namespace: training-jobs
  labels:
    kueue.x-k8s.io/queue-name: training-queue
    kueue.x-k8s.io/priority-class: training-low
spec:
  replicatedJobs:
    - name: leader
      replicas: 1
      template:
        spec:
          parallelism: 1
          completions: 1
          backoffLimit: 0
          template:
            spec:
              nodeSelector:
                cloud.google.com/gke-accelerator: nvidia-rtx-pro-6000
              tolerations:
                - key: nvidia.com/gpu
                  operator: Exists
                  effect: NoSchedule
                - key: sandbox.gke.io/runtime
                  operator: Exists
                  effect: NoSchedule
              containers:
                - name: training-sim
                  image: nvidia/cuda:12.6.3-base-ubuntu24.04
                  command: ["bash", "-c"]
                  args:
                    - |
                      echo "=== Training Job $job_num ==="
                      nvidia-smi
                      sleep infinity
                  resources:
                    requests:
                      nvidia.com/gpu: "1"
                    limits:
                      nvidia.com/gpu: "1"
              restartPolicy: Never
    - name: workers
      replicas: 1
      template:
        spec:
          parallelism: 1
          completions: 1
          backoffLimit: 0
          template:
            spec:
              nodeSelector:
                cloud.google.com/gke-accelerator: nvidia-rtx-pro-6000
              tolerations:
                - key: nvidia.com/gpu
                  operator: Exists
                  effect: NoSchedule
                - key: sandbox.gke.io/runtime
                  operator: Exists
                  effect: NoSchedule
              containers:
                - name: training-sim
                  image: nvidia/cuda:12.6.3-base-ubuntu24.04
                  command: ["bash", "-c"]
                  args:
                    - |
                      echo "=== Training Job $job_num Worker ==="
                      nvidia-smi
                      sleep infinity
                  resources:
                    requests:
                      nvidia.com/gpu: "1"
                    limits:
                      nvidia.com/gpu: "1"
              restartPolicy: Never
EOF
}

wait_for_job() {
  local job_name=$1
  for i in $(seq 1 30); do
    for ctx in worker-east1 worker-west3; do
      count=$(kubectl get pods -n training-jobs --context $ctx -l "jobset.sigs.k8s.io/jobset-name=$job_name" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
      if [ "$count" -ge 2 ]; then
        label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
        color=$([ "$ctx" = "worker-east1" ] && echo "$RED" || echo "$CYAN")
        echo -e "  ${GREEN}✓${NC} ${MAGENTA}$job_name${NC} → dispatched to ${color}${BOLD}$label${NC} (2 GPUs)"
        return 0
      fi
    done
    sleep 2
  done
  echo -e "  ${YELLOW}⏳ $job_name still scheduling...${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# DEMO START
# ─────────────────────────────────────────────────────────────────────────────

clear
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  MultiKueue Demo: Cross-Cluster Training Job Scheduling    ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Training jobs are submitted to the ${BOLD}management cluster${NC}."
echo -e "  MultiKueue evaluates GPU capacity across all worker clusters"
echo -e "  and dispatches each job to a cluster with available resources."
echo ""
echo -e "  ${DIM}Clusters: us-east1 (8 GPUs) + us-west3 (8 GPUs) = 16 GPUs total${NC}"
echo -e "  ${DIM}Each cluster runs 4 inference pods (4 GPUs) → 4 GPUs free each${NC}"
echo ""
echo -e "  Load enters: ${TARGET_COLOR}${BOLD}${TARGET_LABEL}${NC} VIP ($VIP)"
echo -e "  ${DIM}Submitting 3 jobs: 2 on ${OTHER_LABEL} (spillover, preemption target), 1 on ${TARGET_LABEL}${NC}"

pause 5

# ── Step 1: Show initial state ──────────────────────────────────────────────

narrate "Step 1: Current GPU allocation across the fleet"

echo -e "  ${DIM}── Cluster GPU Usage (8 GPUs each) ──${NC}"
show_gpu_state
echo ""
show_mgmt_workloads

pause 4

# Temporarily restrict the TARGET cluster so jobs 1+2 land on the SPILLOVER.
# We set the target ClusterQueue GPU quota to 0, forcing MultiKueue to
# pick the spillover cluster. This happens behind the scenes — the audience just
# sees MultiKueue choosing the cluster with capacity.
kubectl patch clusterqueue gpu-cluster-queue --context $TARGET_CTX --type=merge \
  -p '{"spec":{"resourceGroups":[{"coveredResources":["nvidia.com/gpu"],"flavors":[{"name":"rtx-pro-6000","resources":[{"name":"nvidia.com/gpu","nominalQuota":0}]}]}]}}' \
  2>/dev/null

# ── Step 2: Submit first training job ────────────────────────────────────────

narrate "Step 2: Submit training-job-1 (2 GPUs) from management cluster"
echo -e "  ${DIM}kubectl apply -f training-job-1.yaml --context mgmt${NC}"
echo ""

submit_job "training-job-1" "1"
echo -e "  ${DIM}Waiting for MultiKueue to evaluate cluster capacity...${NC}"
wait_for_job "training-job-1"
echo ""
show_gpu_state

pause 4

# ── Step 3: Submit second training job ───────────────────────────────────────

narrate "Step 3: Submit training-job-2 (2 GPUs) from management cluster"
echo -e "  ${DIM}kubectl apply -f training-job-2.yaml --context mgmt${NC}"
echo ""

submit_job "training-job-2" "2"
echo -e "  ${DIM}Waiting for MultiKueue to evaluate cluster capacity...${NC}"
wait_for_job "training-job-2"
echo ""
show_gpu_state

pause 4

# Restore target cluster quota so job 3 can land there
kubectl patch clusterqueue gpu-cluster-queue --context $TARGET_CTX --type=merge \
  -p '{"spec":{"resourceGroups":[{"coveredResources":["nvidia.com/gpu"],"flavors":[{"name":"rtx-pro-6000","resources":[{"name":"nvidia.com/gpu","nominalQuota":8}]}]}]}}' \
  2>/dev/null
sleep 2

# ── Step 4: Submit third training job ────────────────────────────────────────

narrate "Step 4: Submit training-job-3 (2 GPUs) — ${OTHER_LABEL} is full, MultiKueue dispatches to ${TARGET_LABEL}"
echo -e "  ${DIM}kubectl apply -f training-job-3.yaml --context mgmt${NC}"
echo ""

submit_job "training-job-3" "3"
echo -e "  ${DIM}Waiting for MultiKueue to evaluate cluster capacity...${NC}"
wait_for_job "training-job-3"
echo ""
show_gpu_state

pause 4

# ── Step 5: Final state ─────────────────────────────────────────────────────

narrate "Step 5: Final state — training distributed, room for eviction failover"

echo -e "  ${DIM}── Cluster GPU Usage ──${NC}"
show_gpu_state
echo ""
echo -e "  ${DIM}── MultiKueue Workloads (management cluster) ──${NC}"
show_mgmt_workloads
echo ""
echo -e "  ${DIM}── Training Pods (worker clusters) ──${NC}"
show_worker_training
echo ""

echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  3 training jobs dispatched by MultiKueue.                 ${NC}"
echo -e "${BOLD}  ${OTHER_LABEL}: 4 inference + 4 training = 8/8 GPUs (full)            ${NC}"
echo -e "${BOLD}  ${TARGET_LABEL}: 4 inference + 2 training = 6/8 GPUs (2 free)           ${NC}"
echo -e "${BOLD}                                                            ${NC}"
echo -e "${BOLD}  Next: Load test via ${TARGET_LABEL} VIP ($VIP)              ${NC}"
echo -e "${BOLD}  ${TARGET_LABEL} saturates → GCLB spills to ${OTHER_LABEL}              ${NC}"
echo -e "${BOLD}  ${OTHER_LABEL} HPA scales → preempts training → reschedules to ${TARGET_LABEL}${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

if $RUN_LOAD; then
  pause 3

  narrate "Step 6: Starting load test via ${TARGET_LABEL} VIP ($VIP)"
  echo -e "  ${DIM}python3 load_test.py --concurrency 3000 --max-tokens 512 --target-cluster $TARGET --mode load${NC}"
  echo ""

  pause 2

  exec python3 load_test.py --concurrency 3000 --max-tokens 512 --target-cluster "$TARGET" --mode load
else
  echo -e "  Run: ${BOLD}python3 load_test.py --concurrency 3000 --max-tokens 512 --target-cluster $TARGET --mode load${NC}"
  echo ""
fi
