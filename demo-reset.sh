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

reset_loadtest() {
  echo "=== Resetting Load Test (target: $TARGET) ==="
  echo ""

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

show_state() {
  echo ""
  echo "=== Validation ==="

  all_ok=true
  for ctx in worker-east1 worker-west3; do
    label=$([ "$ctx" = "worker-east1" ] && echo "east1" || echo "west3")

    # Count inference pods (all states)
    inf_running=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --no-headers 2>/dev/null | grep -c "Running" || true)
    inf_other=$(kubectl get pods -n inference-server --context $ctx -l app=vllm-llama3-8b-instruct --no-headers 2>/dev/null | grep -cv "Running" || true)

    # Count training pods
    train_total=$(kubectl get pods -n training-jobs --context $ctx --no-headers 2>/dev/null | wc -l)

    # Check actual GPU allocation on GPU nodes
    gpus_used=0
    for node in $(kubectl get nodes --context $ctx -l cloud.google.com/gke-accelerator=nvidia-rtx-pro-6000 -o name 2>/dev/null); do
      node_gpus=$(kubectl get pods --all-namespaces --context $ctx --field-selector spec.nodeName=$(echo $node | cut -d/ -f2) -o jsonpath='{range .items[*]}{.spec.containers[0].resources.requests.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
      gpus_used=$((gpus_used + node_gpus))
    done
    gpus_free=$((8 - gpus_used))

    # HPA
    hpa_min=$(kubectl get hpa vllm-inference-hpa -n inference-server --context $ctx -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
    hpa_max=$(kubectl get hpa vllm-inference-hpa -n inference-server --context $ctx -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)

    # Validate
    errors=""
    [ "$inf_running" -ne 4 ] && errors="${errors} inference=${inf_running}/4"
    [ "$inf_other" -gt 0 ] && errors="${errors} stale_pods=${inf_other}"
    [ "$train_total" -gt 0 ] && errors="${errors} training=${train_total}"
    [ "$gpus_free" -lt 4 ] && errors="${errors} free_gpus=${gpus_free}/4"

    if [ -z "$errors" ]; then
      echo "  ✓ $label: 4 inference Running, ${gpus_free} GPUs free, HPA min=${hpa_min} max=${hpa_max}"
    else
      echo "  ✗ $label: ISSUES:${errors}  (GPUs: ${gpus_used}/8 used, ${gpus_free} free, HPA min=${hpa_min} max=${hpa_max})"
      all_ok=false
    fi
  done

  if ! $all_ok; then
    echo ""
    echo "  ⚠  Environment has issues. You may need to wait for pods to terminate"
    echo "     or run the reset again. Check with:"
    echo "     kubectl get pods -n inference-server --context worker-east1"
    echo "     kubectl get pods -n inference-server --context worker-west3"
    echo ""
  fi

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
