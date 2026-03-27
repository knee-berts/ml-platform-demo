#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Demo Reset Script
#
# Usage:
#   ./demo-reset.sh --target east1                  # Reset all, HPA scales on east1
#   ./demo-reset.sh --target west3                  # Reset all, HPA scales on west3
#   ./demo-reset.sh --multikueue --target east1     # Reset only training jobs
#   ./demo-reset.sh --loadtest --target west3       # Reset only load test
# ─────────────────────────────────────────────────────────────────────────────
set -eE

# Parse args
MODE=""
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --multikueue) MODE="multikueue" ;;
    --loadtest) MODE="loadtest" ;;
    --target) :;; # next arg
    east1) TARGET="east1" ;;
    west3) TARGET="west3" ;;
  esac
done
# Handle --target <value>
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) shift ;;
  esac
done

MODE="${MODE:-all}"

if [ -z "$TARGET" ]; then
  echo "Usage: $0 [--all | --multikueue | --loadtest] --target <east1|west3>"
  echo ""
  echo "  --target east1   Load test targets east1 (east1 HPA max=6, west3 HPA max=4)"
  echo "  --target west3   Load test targets west3 (west3 HPA max=6, east1 HPA max=4)"
  echo "  --all            Reset everything (default)"
  echo "  --multikueue     Reset only training jobs"
  echo "  --loadtest       Reset only load test"
  exit 1
fi

if [ "$TARGET" = "east1" ]; then
  TARGET_CTX="worker-east1"
  OTHER_CTX="worker-west3"
else
  TARGET_CTX="worker-west3"
  OTHER_CTX="worker-east1"
fi

# Trap: always restore HPAs on exit (target gets max 6, other gets max 4)
trap 'kubectl patch hpa vllm-inference-hpa -n inference-server --context '"$TARGET_CTX"' --type=merge -p "{\"spec\":{\"minReplicas\":4,\"maxReplicas\":6}}" 2>/dev/null
kubectl patch hpa vllm-inference-hpa -n inference-server --context '"$OTHER_CTX"' --type=merge -p "{\"spec\":{\"minReplicas\":4,\"maxReplicas\":4}}" 2>/dev/null' ERR EXIT

remediate_disk_pressure() {
  # Replace GPU nodes with DiskPressure so pods can schedule on fresh nodes.
  # Root cause: HF model cache fills the boot disk across pod restarts.
  echo "--- Checking for DiskPressure on GPU nodes ---"
  for ctx in worker-east1 worker-west3; do
    local label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
    for node in $(kubectl get nodes --context $ctx -l cloud.google.com/gke-accelerator=nvidia-rtx-pro-6000 \
        -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="DiskPressure")].status}{" "}{end}' 2>/dev/null); do
      name="${node%%=*}"
      status="${node##*=}"
      if [ "$status" = "True" ]; then
        echo "  ⚠ $label/$name has DiskPressure — draining and deleting for replacement"
        # Force-delete inference pods on this node (they'll hang on graceful shutdown with full disk)
        kubectl delete pods -n inference-server -l app=vllm-llama3-8b-instruct --context $ctx \
          --field-selector spec.nodeName=$name --grace-period=0 --force --ignore-not-found 2>/dev/null || true
        # Cordon + delete (GKE autoscaler will provision a fresh node)
        kubectl cordon "$name" --context $ctx 2>/dev/null || true
        kubectl delete node "$name" --context $ctx 2>/dev/null || true
        echo "  → $label/$name deleted, waiting for GKE to provision replacement..."
      fi
    done
  done

  # If any nodes were replaced, wait for new ones to become Ready
  for ctx in worker-east1 worker-west3; do
    local label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
    local expected=2
    for i in $(seq 1 60); do
      local ready_count
      ready_count=$(kubectl get nodes --context $ctx -l cloud.google.com/gke-accelerator=nvidia-rtx-pro-6000 \
        --no-headers 2>/dev/null | grep -c " Ready" || true)
      if [ "$ready_count" -ge "$expected" ]; then
        break
      fi
      if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
        echo "  $label: ${ready_count}/${expected} GPU nodes Ready, waiting... (${i}/60)"
      fi
      sleep 10
    done
  done
}

reset_loadtest() {
  echo "=== Resetting Load Test (target: $TARGET) ==="
  echo ""

  # Fix unhealthy nodes before anything else
  remediate_disk_pressure

  # Kill any load generator pods
  echo "--- Killing load generators ---"
  kubectl delete pod kv-load-gen -n inference-server --context worker-east1 --ignore-not-found --wait=false 2>/dev/null
  kubectl delete pod kv-load-gen-west3 -n inference-server --context worker-west3 --ignore-not-found --wait=false 2>/dev/null

  # Pause HPAs to prevent scaling while we clean up
  echo "--- Pausing HPAs ---"
  kubectl patch hpa vllm-inference-hpa -n inference-server --context worker-east1 --type=merge -p '{"spec":{"minReplicas":4,"maxReplicas":4}}' 2>/dev/null
  kubectl patch hpa vllm-inference-hpa -n inference-server --context worker-west3 --type=merge -p '{"spec":{"minReplicas":4,"maxReplicas":4}}' 2>/dev/null

  # Scale to 4 (handles both scale-down from >4 and scale-up from <4)
  echo "--- Ensuring 4 inference replicas ---"
  kubectl scale deployment vllm-llama3-8b-instruct -n inference-server --context worker-east1 --replicas=4
  kubectl scale deployment vllm-llama3-8b-instruct -n inference-server --context worker-west3 --replicas=4

  # Clean broken pods and stale workloads (without touching healthy Running pods)
  echo "--- Cleaning broken pods ---"
  for ctx in worker-east1 worker-west3; do
    # Count broken pods
    broken=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --no-headers 2>/dev/null | grep -cEv "Running|Terminating" || true)
    if [ "$broken" -gt 0 ]; then
      echo "  $ctx: removing $broken broken pods..."
      # Scale to 0 only if there are broken pods holding GPUs
      kubectl patch hpa vllm-inference-hpa -n inference-server --context $ctx --type=merge -p '{"spec":{"minReplicas":1,"maxReplicas":1}}' 2>/dev/null
      kubectl scale deployment vllm-llama3-8b-instruct -n inference-server --context $ctx --replicas=0
      kubectl wait --for=delete pod -l app=vllm-llama3-8b-instruct -n inference-server --context $ctx --timeout=180s 2>/dev/null || true
      # Force clean any ghosts
      kubectl delete pods -l app=vllm-llama3-8b-instruct -n inference-server --context $ctx --grace-period=0 --force --ignore-not-found 2>/dev/null || true
      kubectl delete workloads --all -n inference-server --context $ctx --ignore-not-found 2>/dev/null || true
      sleep 5
      # Restore HPA before scaling back up so it doesn't clamp replicas
      if [ "$ctx" = "$TARGET_CTX" ]; then
        kubectl patch hpa vllm-inference-hpa -n inference-server --context $ctx --type=merge -p '{"spec":{"minReplicas":4,"maxReplicas":6}}' 2>/dev/null
      else
        kubectl patch hpa vllm-inference-hpa -n inference-server --context $ctx --type=merge -p '{"spec":{"minReplicas":4,"maxReplicas":4}}' 2>/dev/null
      fi
      kubectl scale deployment vllm-llama3-8b-instruct -n inference-server --context $ctx --replicas=4
    else
      # Just wait for any terminating pods and clean finished workloads
      kubectl wait --for=delete pod -l app=vllm-llama3-8b-instruct -n inference-server --context $ctx --field-selector=metadata.deletionTimestamp!='' --timeout=180s 2>/dev/null || true
      # Clean only finished workloads
      kubectl get workloads -n inference-server --context $ctx -o jsonpath='{range .items[*]}{.metadata.name}|{.status.conditions[?(@.type=="Finished")].status}{"\n"}{end}' 2>/dev/null | while read -r line; do
        name=$(echo "$line" | cut -d'|' -f1)
        finished=$(echo "$line" | cut -d'|' -f2)
        [ "$finished" = "True" ] && [ -n "$name" ] && kubectl delete workload "$name" -n inference-server --context $ctx --ignore-not-found 2>/dev/null || true
      done || true
    fi
  done

  # Wait for rollout
  echo "--- Waiting for inference pods to be ready ---"
  kubectl rollout status deployment/vllm-llama3-8b-instruct -n inference-server --context worker-east1 --timeout=300s &
  kubectl rollout status deployment/vllm-llama3-8b-instruct -n inference-server --context worker-west3 --timeout=300s &
  wait

  # Restore HPAs to correct values before validation
  echo "--- Restoring HPAs (target max=6, other max=4) ---"
  kubectl patch hpa vllm-inference-hpa -n inference-server --context "$TARGET_CTX" --type=merge -p '{"spec":{"minReplicas":4,"maxReplicas":6}}' 2>/dev/null
  kubectl patch hpa vllm-inference-hpa -n inference-server --context "$OTHER_CTX" --type=merge -p '{"spec":{"minReplicas":4,"maxReplicas":4}}' 2>/dev/null

  # Wait for KV cache to drain
  echo "--- Waiting 15s for KV cache to cool ---"
  sleep 15

  echo "--- Load test reset complete ---"
}

reset_multikueue() {
  echo "=== Resetting MultiKueue Training Jobs ==="
  echo ""

  # Delete all training jobs from mgmt and workers
  echo "--- Clearing training jobs ---"
  kubectl delete jobset --all -n training-jobs --context mgmt --ignore-not-found 2>/dev/null
  kubectl delete jobset --all -n training-jobs --context worker-east1 --ignore-not-found 2>/dev/null
  kubectl delete jobset --all -n training-jobs --context worker-west3 --ignore-not-found 2>/dev/null

  # Force-delete training pods to speed up cleanup
  echo "--- Force-deleting training pods ---"
  for ctx in worker-east1 worker-west3; do
    kubectl delete pods --all -n training-jobs --context $ctx --grace-period=0 --force --ignore-not-found 2>/dev/null
  done

  # Wait until training pods are actually gone
  echo "--- Waiting for training pod cleanup ---"
  for ctx in worker-east1 worker-west3; do
    for i in $(seq 1 30); do
      count=$(kubectl get pods -n training-jobs --context $ctx --no-headers 2>/dev/null | wc -l)
      [ "$count" -eq 0 ] && break
      sleep 2
    done
  done

  # Clean up any finished workloads on workers
  for ctx in worker-east1 worker-west3; do
    kubectl delete workloads --all -n training-jobs --context $ctx --ignore-not-found 2>/dev/null
  done

  # Ensure ClusterQueue quotas are restored (may have been zeroed by demo-multikueue.sh)
  echo "--- Restoring ClusterQueue quotas ---"
  for ctx in worker-east1 worker-west3; do
    kubectl patch clusterqueue gpu-cluster-queue --context $ctx --type=merge \
      -p '{"spec":{"resourceGroups":[{"coveredResources":["nvidia.com/gpu"],"flavors":[{"name":"rtx-pro-6000","resources":[{"name":"nvidia.com/gpu","nominalQuota":8}]}]}]}}' 2>/dev/null || true
  done

  echo "--- MultiKueue reset complete ---"
}

VALIDATION_RETRIES=30       # max attempts (× 10s = 5 minutes)
VALIDATION_INTERVAL=10      # seconds between retries

validate_environment() {
  # Returns 0 if ready, 1 if not. Prints per-cluster status.
  local all_ok=true

  for ctx in worker-east1 worker-west3; do
    local label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
    local errors=""

    # ── Node health ──────────────────────────────────────────────
    local bad_nodes=""
    bad_nodes=$(kubectl get nodes --context $ctx -l cloud.google.com/gke-accelerator=nvidia-rtx-pro-6000 \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' 2>/dev/null \
      | while read -r node conds; do
          for c in $conds; do
            case "$c" in
              Ready=True) ;;
              Ready=*)             echo "$node:NotReady" ;;
              DiskPressure=True)   echo "$node:DiskPressure" ;;
              MemoryPressure=True) echo "$node:MemoryPressure" ;;
              PIDPressure=True)    echo "$node:PIDPressure" ;;
            esac
          done
        done)
    if [ -n "$bad_nodes" ]; then
      errors="${errors} node_issues=[${bad_nodes}]"
    fi

    # ── Inference pods ───────────────────────────────────────────
    local inf_running
    inf_running=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --no-headers 2>/dev/null | grep -c "Running" || true)
    local inf_ready
    inf_ready=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/[0-9]+$/ { split($2,a,"/"); if(a[1]==a[2] && $3=="Running") c++ } END {print c+0}')
    local inf_other
    inf_other=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --no-headers 2>/dev/null | grep -cvE "Running|Terminating" || true)

    [ "$inf_ready" -ne 4 ] && errors="${errors} inference_ready=${inf_ready}/4"
    [ "$inf_other" -gt 0 ] && errors="${errors} stale_pods=${inf_other}"

    # ── Training pods (should be zero) ───────────────────────────
    local train_total
    train_total=$(kubectl get pods -n training-jobs --context $ctx --no-headers 2>/dev/null | wc -l)
    [ "$train_total" -gt 0 ] && errors="${errors} training_pods=${train_total}"

    # ── GPU capacity ─────────────────────────────────────────────
    local gpus_used=0
    for node in $(kubectl get nodes --context $ctx -l cloud.google.com/gke-accelerator=nvidia-rtx-pro-6000 -o name 2>/dev/null); do
      local node_gpus
      node_gpus=$(kubectl get pods --all-namespaces --context $ctx --field-selector spec.nodeName=$(echo $node | cut -d/ -f2) -o jsonpath='{range .items[*]}{.spec.containers[0].resources.requests.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
      gpus_used=$((gpus_used + node_gpus))
    done
    local gpus_free=$((8 - gpus_used))
    [ "$gpus_free" -lt 4 ] && errors="${errors} free_gpus=${gpus_free}/4"

    # ── HPA ──────────────────────────────────────────────────────
    local hpa_min hpa_max
    hpa_min=$(kubectl get hpa vllm-inference-hpa -n inference-server --context $ctx -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
    hpa_max=$(kubectl get hpa vllm-inference-hpa -n inference-server --context $ctx -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)

    if [ -z "$errors" ]; then
      echo "  ✓ $label: 4 inference ready, ${gpus_free} GPUs free, HPA min=${hpa_min} max=${hpa_max}"
    else
      echo "  ✗ $label: ISSUES:${errors}  (GPUs: ${gpus_used}/8 used, ${gpus_free} free, HPA min=${hpa_min} max=${hpa_max})"
      all_ok=false
    fi
  done

  $all_ok
}

show_state() {
  echo ""
  echo "=== Validating environment ==="

  local attempt=1
  while [ $attempt -le $VALIDATION_RETRIES ]; do
    if validate_environment; then
      break
    fi

    if [ $attempt -eq $VALIDATION_RETRIES ]; then
      echo ""
      echo "  ✗ Environment NOT ready after $((VALIDATION_RETRIES * VALIDATION_INTERVAL))s. Aborting."
      echo "    Debug:"
      echo "      kubectl get pods -n inference-server --context worker-east1"
      echo "      kubectl get pods -n inference-server --context worker-west3"
      echo "      kubectl get nodes --context worker-east1 -o wide"
      echo "      kubectl get nodes --context worker-west3 -o wide"
      exit 1
    fi

    echo "  … retrying in ${VALIDATION_INTERVAL}s (attempt ${attempt}/${VALIDATION_RETRIES})"
    sleep "$VALIDATION_INTERVAL"
    attempt=$((attempt + 1))
  done

  echo ""
  echo "=== Current State (target: $TARGET) ==="
  for ctx in worker-east1 worker-west3; do
    label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")
    inf=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    train=$(kubectl get pods -n training-jobs --context $ctx --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    hpa_max=$(kubectl get hpa vllm-inference-hpa -n inference-server --context $ctx -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
    echo "  $label: ${inf} inference + ${train} training = $((inf + train))/8 GPUs  (HPA max: $hpa_max)"
  done
  echo ""
  echo "Ready to run:"
  echo "  ./demo-multikueue.sh --target $TARGET             # MultiKueue demo"
  if [ "$TARGET" = "east1" ]; then
    echo "  python3 load_test.py --vip 10.142.0.74 --concurrency 300   # Load test east1"
  else
    echo "  python3 load_test.py --target-cluster west3 --concurrency 300   # Load test west3"
  fi
}

case "$MODE" in
  loadtest)
    reset_loadtest
    show_state
    ;;
  multikueue)
    reset_multikueue
    show_state
    ;;
  all)
    reset_loadtest
    echo ""
    reset_multikueue
    show_state
    ;;
  *)
    echo "Usage: $0 [--all | --multikueue | --loadtest] --target <east1|west3>"
    exit 1
    ;;
esac
