#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Preemption Demo — Shows Kueue scheduling, HPA-driven preemption, and
# critical job priority escalation across multi-cluster GPU fleet.
#
# Flow:
#   1. Submit 30 low-priority 1-GPU experiments (60s each)
#   2. Start load test → HPA scales inference → evicts experiments
#   3. Submit 1 critical 3-GPU pre-training job that preempts inference
#
# Kueue orchestration details are shown in the load_test.py dashboard.
#
# Usage:
#   ./demo-preemption.sh              # Interactive mode
#   ./demo-preemption.sh --auto       # Automated with pauses
# ─────────────────────────────────────────────────────────────────────────────
set -e

# Fix for terminals not recognized on remote hosts (e.g. Ghostty)
case "$TERM" in xterm-ghostty|*-unknown) export TERM=xterm-256color ;; esac

AUTO=false
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=true ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
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

# ── Cleanup ───────────────────────────────────────────────────────────────────
LOAD_TEST_PID=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cleanup_bad_pods() {
  # Force-delete pods stuck in Terminating or CrashLoopBackOff (0/2 Ready)
  for ctx in worker-east1 worker-west3; do
    # Terminating pods (have a deletionTimestamp but haven't gone away)
    local stuck
    stuck=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct \
      -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{" "}{end}' 2>/dev/null)
    if [ -n "$stuck" ]; then
      echo -e "  ${YELLOW}Force-deleting stuck Terminating pods on $ctx:${NC} $stuck"
      kubectl delete pods $stuck -n inference-server --context $ctx --force --grace-period=0 2>/dev/null || true
    fi
    # Pods with 0 ready containers that have been restarting (restartCount > 3)
    local broken
    broken=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}' 2>/dev/null \
      | awk -F'|' '{split($2,a,","); max=0; for(i in a){if(a[i]+0>max)max=a[i]+0} if(max>3)print $1}')
    if [ -n "$broken" ]; then
      echo -e "  ${YELLOW}Deleting crash-looping pods on $ctx:${NC} $broken"
      kubectl delete pods $broken -n inference-server --context $ctx --force --grace-period=0 2>/dev/null || true
    fi
  done
}

do_cleanup() {
  echo ""
  echo -e "${YELLOW}Cleaning up...${NC}"
  # Kill load test if running
  if [ -n "$LOAD_TEST_PID" ] && kill -0 "$LOAD_TEST_PID" 2>/dev/null; then
    echo -e "  ${DIM}Stopping load test (PID: $LOAD_TEST_PID)...${NC}"
    kill "$LOAD_TEST_PID" 2>/dev/null || true
    wait "$LOAD_TEST_PID" 2>/dev/null || true
  fi
  # Delete all jobs
  echo -e "  ${DIM}Deleting experiment and pre-training jobs...${NC}"
  for i in $(seq 1 40); do
    kubectl delete jobset "experiment-$i" -n training-jobs --context mgmt --ignore-not-found=true 2>/dev/null &
  done
  kubectl delete jobset "pre-training-1" -n training-jobs --context mgmt --ignore-not-found=true 2>/dev/null &
  wait
  # Clean up bad pods
  cleanup_bad_pods
  # Reset HPAs back to min=2, max=6 and scale deployments to 2 replicas
  echo -e "  ${DIM}Resetting HPAs to min=2, max=6...${NC}"
  kubectl apply -f "$SCRIPT_DIR/kueue/hpa-inference.yaml" --context worker-east1 2>/dev/null || true
  kubectl apply -f "$SCRIPT_DIR/kueue/hpa-inference.yaml" --context worker-west3 2>/dev/null || true
  kubectl scale deployment vllm-llama3-8b-instruct -n inference-server --replicas=2 --context worker-east1 2>/dev/null || true
  kubectl scale deployment vllm-llama3-8b-instruct -n inference-server --replicas=2 --context worker-west3 2>/dev/null || true
  echo -e "${GREEN}Cleanup complete.${NC}"
}

trap '' EXIT INT TERM  # overridden below after pre-flight

# ── Helper: show GPU state across clusters ────────────────────────────────────
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
    echo -e "  ${BOLD}$label${NC}  [${bar}]  ${CYAN}${inf}i${NC} ${MAGENTA}${train}t${NC} ${DIM}${free} free${NC}"
  done
  echo -e "  ${DIM}Legend: ${CYAN}█${NC}${DIM}=inference ${MAGENTA}█${NC}${DIM}=training ░=free${NC}"
}

# ── Helper: submit experiment (1 GPU, 30s) ────────────────────────────────────
submit_small_job() {
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
    - name: worker
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
                      echo "=== Experiment $job_num ==="
                      nvidia-smi
                      echo "Running experiment for 60 seconds..."
                      sleep 60
                      echo "Experiment complete."
                  resources:
                    requests:
                      nvidia.com/gpu: "1"
                    limits:
                      nvidia.com/gpu: "1"
              restartPolicy: Never
EOF
}

# ── Helper: submit pre-training job (3 GPU, 2min) ────────────────────────────
submit_critical_job() {
  cat <<EOF | kubectl apply --context mgmt -f - 2>&1 | grep -v "^$"
apiVersion: jobset.x-k8s.io/v1alpha2
kind: JobSet
metadata:
  name: pre-training-1
  namespace: training-jobs
  labels:
    kueue.x-k8s.io/queue-name: training-queue
    kueue.x-k8s.io/priority-class: training-critical
spec:
  replicatedJobs:
    - name: worker
      replicas: 3
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
                      echo "=== Pre-Training Job (3 GPUs) ==="
                      nvidia-smi
                      echo "Pre-training for 2 minutes..."
                      sleep 120
                      echo "Pre-training complete."
                  resources:
                    requests:
                      nvidia.com/gpu: "1"
                    limits:
                      nvidia.com/gpu: "1"
              restartPolicy: Never
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT: clean up bad pods before starting
# ─────────────────────────────────────────────────────────────────────────────

echo -e "${DIM}Pre-flight: checking for stuck or crash-looping inference pods...${NC}"
cleanup_bad_pods
echo ""

# Now set the trap — on unexpected exit (Ctrl-C), prompt for cleanup
trap 'echo ""; echo -e "${YELLOW}Interrupted.${NC}"; echo -n "Run cleanup? [Y/n] "; read -r ans; case "$ans" in [nN]*) echo -e "${DIM}Skipped cleanup.${NC}" ;; *) do_cleanup ;; esac; exit 1' INT TERM
trap '' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# DEMO START
# ─────────────────────────────────────────────────────────────────────────────

clear
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Kueue Preemption Demo: Priority Scheduling on GPU Fleet   ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  This demo shows three levels of GPU workload priority:"
echo -e "  ${MAGENTA}1.${NC} Low-priority experiments fill available GPU capacity"
echo -e "  ${CYAN}2.${NC} Inference HPA scales up under load, evicting experiments"
echo -e "  ${RED}3.${NC} Critical pre-training job preempts even inference servers"
echo ""
echo -e "  ${DIM}Clusters: us-east1 (8 GPUs) + us-west3 (8 GPUs) = 16 GPUs total${NC}"
echo ""

narrate "Initial GPU state"
show_gpu_state

pause 4

# ── Step 1: Submit 20 low-priority experiments ────────────────────────────────

narrate "Step 1: Scheduling 40 low-priority experiments (1 GPU each, 60s duration)"
echo -e "  ${DIM}Submitting to management cluster → MultiKueue distributes across fleet${NC}"
echo ""

for i in $(seq 1 40); do
  submit_small_job "experiment-$i" "$i" > /dev/null 2>&1
  printf "\r  Submitted ${BOLD}%d${NC}/40 jobs..." "$i"
done
echo ""
echo ""

echo -e "  ${DIM}Waiting for jobs to be admitted and dispatched...${NC}"
sleep 10

show_gpu_state

pause 4

# ── Step 2: Start load test ──────────────────────────────────────────────────

narrate "Step 2: Starting inference load test → HPA will scale up and evict experiments"
echo -e "  ${DIM}Launching load_test.py (concurrency=3000, max-tokens=512, target=east1)${NC}"
echo ""

python3 "$SCRIPT_DIR/load_test.py" --concurrency 3000 --max-tokens 512 --target-cluster east1 --mode load >/dev/null 2>&1 &
LOAD_TEST_PID=$!

echo -e "  ${GREEN}✓${NC} Load test started"
echo -e "  ${DIM}KV-cache will fill → HPA scales inference pods → experiments evicted${NC}"
echo ""

# Monitor HPA scale-up
echo -e "  ${DIM}Monitoring GPU state (load takes ~60s to saturate KV-cache)...${NC}"
for tick in $(seq 1 6); do
  sleep 15
  echo ""
  echo -e "  ${DIM}── $(date +%H:%M:%S) ──${NC}"
  show_gpu_state
done

pause 4

# ── Step 3: Submit critical 3-GPU job ────────────────────────────────────────

narrate "Step 3: Submitting critical 3-GPU pre-training job (priority > inference)"
echo -e "  ${DIM}Priority: training-critical (2000) > inference-high (1000) > training-low (100)${NC}"
echo -e "  ${DIM}Kueue will preempt inference servers to make room for pre-training${NC}"
echo ""

submit_critical_job
echo ""

echo -e "  ${DIM}Waiting for pre-training job to be admitted...${NC}"
for tick in $(seq 1 8); do
  sleep 15
  echo ""
  echo -e "  ${DIM}── $(date +%H:%M:%S) ──${NC}"
  show_gpu_state
  # Check if critical job pods are running
  for ctx in worker-east1 worker-west3; do
    count=$(kubectl get pods -n training-jobs --context $ctx -l "jobset.sigs.k8s.io/jobset-name=pre-training-1" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$count" -ge 3 ]; then
      label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
      echo ""
      echo -e "  ${GREEN}✓${NC} ${RED}${BOLD}pre-training-1${NC} running on ${BOLD}$label${NC} — 3 GPUs claimed, inference preempted"
      break 2
    fi
  done
done

pause 4

# ── Step 4: Final state ──────────────────────────────────────────────────────

narrate "Final state"
show_gpu_state

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Demo complete.                                            ${NC}"
echo -e "${BOLD}                                                            ${NC}"
echo -e "${BOLD}  Key takeaways:                                            ${NC}"
echo -e "${BOLD}  • Low-priority experiments fill spare GPU capacity        ${NC}"
echo -e "${BOLD}  • Inference HPA reclaims GPUs as demand grows             ${NC}"
echo -e "${BOLD}  • Pre-training jobs preempt even inference when needed     ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Prompt for cleanup
echo ""
echo -n -e "${YELLOW}Run cleanup (delete jobs, reset HPAs, remove bad pods)? [Y/n] ${NC}"
read -r ans
case "$ans" in
  [nN]*) echo -e "${DIM}Skipped cleanup. Resources left in place.${NC}" ;;
  *)     do_cleanup ;;
esac
