#!/bin/bash
# install.sh — one-command end-to-end install of the multi-cluster inference demo.
#
# Required env:
#   PROJECT_ID  GCP project to provision into. Must have billing enabled and
#               your gcloud user/SA must have Owner (or equivalent).
#   HF_TOKEN    HuggingFace API token with access to meta-llama/Llama-3.1-8B-Instruct.
#               Sign in at https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct
#               to accept the license, then create a token at
#               https://huggingface.co/settings/tokens.
#
# Optional env:
#   REGION                Default us-east1 (mgmt cluster + AR + most workloads).
#   WORKER_REGIONS        Default "us-east1 us-west3" (space-separated).
#   GOOGLE_APPLICATION_CREDENTIALS  Path to a SA key file. Required when running
#                                   the SA from a project different than PROJECT_ID.
#   SKIP_DEMO             Set to 1 to NOT auto-run demo-preemption.sh after install.
#   SKIP_IMAGE_BUILDS     Set to 1 to skip the 4 Cloud Build image submissions
#                         (gcp-auth-plugin, kueue-with-gcp-auth, dispatcher, vllm).
#                         Use when the images already exist in AR — saves ~20 min.
#   SKIP_WEIGHTS_UPLOAD   Set to 1 to skip the Llama 3.1 8B weights upload.
#                         Use when the model bucket is already populated.
#
# Optional terraform var overrides (each forwarded into the generated tfvars
# of the relevant stack — leave unset to take the variable's terraform default):
#   MANAGE_PROJECT_SERVICES         Stack 1. Set to "false" when the SA running
#                                   terraform can't pass the provider's
#                                   serviceusage LIST refresh check (cross-project
#                                   SAs in policy-restricted projects). Enable
#                                   APIs manually with `gcloud services enable`
#                                   when this is false.
#   ENABLE_BLACKWELL_POOL           Stack 1. Set to "true" only if the project has
#                                   RTX PRO 6000 quota in WORKER_REGIONS.
#   ENABLE_POD_SNAPSHOT             Stack 3. Set to "false" on clusters without
#                                   the podsnapshot.gke.io CRDs (non-Enterprise GKE).
#
# What this does:
#   1. Verifies prereqs and enables required APIs.
#   2. terraform apply ./terraform   (1-infrastructure)
#   3. Builds 4 images via Cloud Build (gcp-auth-plugin, kueue-with-gcp-auth,
#      dispatcher, vllm), in parallel where deps allow.
#   4. Uploads Llama 3.1 8B weights to gs://<project>-model-weights via Cloud Build
#      (uses HF_TOKEN out of Secret Manager).
#   5. terraform apply ./2-multikueue
#   6. terraform apply ./3-multi-cluster-inference-gateway (TF_VAR_hf_token=$HF_TOKEN)
#   7. Renames kubectl contexts to mgmt / worker-east1 / worker-west3.
#   8. Optionally runs demo-preemption.sh.
#
# Total wall-clock: ~30-45 min (cluster creation + vLLM image push + weights download).

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Config + prereqs
# ─────────────────────────────────────────────────────────────────────────────

: "${PROJECT_ID:?Set PROJECT_ID environment variable}"
: "${HF_TOKEN:?Set HF_TOKEN environment variable}"

REGION="${REGION:-us-east1}"
# Default workers are two regions that both have NVIDIA L4 capacity
# (g2-standard-* machine types) so the inference-gpu ComputeClass can
# provision on either. us-west3 was previously the second worker but it has
# no L4 GPUs, so the chart's L4-only fallback never schedules there.
WORKER_REGIONS="${WORKER_REGIONS:-us-east1 us-central1}"
SKIP_DEMO="${SKIP_DEMO:-0}"
SKIP_IMAGE_BUILDS="${SKIP_IMAGE_BUILDS:-0}"
SKIP_WEIGHTS_UPLOAD="${SKIP_WEIGHTS_UPLOAD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_INFRA="$ROOT_DIR/terraform"
TF_KUEUE="$ROOT_DIR/2-multikueue"
TF_MCIG="$ROOT_DIR/3-multi-cluster-inference-gateway"

# Image refs (must match what the helm releases expect).
AR_REPO_VLLM="${REGION}-docker.pkg.dev/${PROJECT_ID}/vllm-blackwell"
AR_REPO_AUTH="${REGION}-docker.pkg.dev/${PROJECT_ID}/gcp-auth-plugin"

VLLM_IMAGE="${AR_REPO_VLLM}/vllm-blackwell:latest"
GCP_AUTH_PLUGIN_IMAGE="${AR_REPO_AUTH}/gcp-auth-plugin:v0.0.1"
KUEUE_IMAGE="${AR_REPO_VLLM}/kueue-with-gcp-auth"
KUEUE_TAG="0.15.1"
DISPATCHER_IMAGE="${AR_REPO_VLLM}/least-disruption-dispatcher:latest"

MODEL_WEIGHTS_BUCKET="${PROJECT_ID}-model-weights"
MODEL_WEIGHTS_PATH="gs://${MODEL_WEIGHTS_BUCKET}/meta-llama/Llama-3.1-8B-Instruct/"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

c_blue=$'\e[34m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_dim=$'\e[2m'; c_reset=$'\e[0m'

step() { echo "${c_blue}━━━ $* ━━━${c_reset}"; }
ok()   { echo "${c_green}✓ $*${c_reset}"; }
warn() { echo "${c_yellow}! $*${c_reset}"; }
die()  { echo "${c_red}✗ $*${c_reset}" >&2; exit 1; }

terraform_bin() {
  command -v terraform >/dev/null 2>&1 && echo terraform && return
  [ -x /tmp/terraform ] && echo /tmp/terraform && return
  die "terraform binary not found in PATH or /tmp/terraform"
}
TERRAFORM=$(terraform_bin)

# ─────────────────────────────────────────────────────────────────────────────
# 0. Prereq checks
# ─────────────────────────────────────────────────────────────────────────────

step "Prereq checks"

command -v gcloud  >/dev/null 2>&1 || die "gcloud not installed"
command -v kubectl >/dev/null 2>&1 || die "kubectl not installed"
command -v helm    >/dev/null 2>&1 || die "helm not installed"
command -v jq      >/dev/null 2>&1 || die "jq not installed (used to parse terraform outputs)"
$TERRAFORM version >/dev/null 2>&1 || die "terraform not runnable"

if ! gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null 2>&1; then
  die "Cannot describe project '$PROJECT_ID' — check PROJECT_ID and gcloud auth"
fi

ok "Project $PROJECT_ID accessible"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Enable required APIs
# ─────────────────────────────────────────────────────────────────────────────

step "Enabling APIs"

gcloud services enable --project="$PROJECT_ID" \
  cloudbuild.googleapis.com \
  cloudresourcemanager.googleapis.com \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  gkehub.googleapis.com \
  connectgateway.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  trafficdirector.googleapis.com \
  multiclusteringress.googleapis.com \
  multiclusterservicediscovery.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com >/dev/null
ok "APIs enabled"

# ─────────────────────────────────────────────────────────────────────────────
# 2. terraform apply 1-infrastructure
# ─────────────────────────────────────────────────────────────────────────────

step "1-infrastructure (clusters, fleet, AR, buckets)"

{
  echo "# Generated by scripts/install.sh — do not commit."
  echo "project_id     = \"$PROJECT_ID\""
  echo "region         = \"$REGION\""
  echo "worker_regions = [$(printf '"%s",' $WORKER_REGIONS | sed 's/,$//')]"
  [ -n "${MANAGE_PROJECT_SERVICES:-}" ] && echo "manage_project_services = $MANAGE_PROJECT_SERVICES"
  [ -n "${ENABLE_BLACKWELL_POOL:-}" ]   && echo "enable_blackwell_pool   = $ENABLE_BLACKWELL_POOL"
} > "$TF_INFRA/terraform.tfvars"

(cd "$TF_INFRA" && $TERRAFORM init -input=false -upgrade) >/dev/null
(cd "$TF_INFRA" && $TERRAFORM apply -input=false -auto-approve)

ok "terraform/ applied"

# Capture cluster connection details for kubectl context renaming below.
mapfile -t WORKER_CLUSTER_NAMES < <(cd "$TF_INFRA" && $TERRAFORM output -json worker_cluster_names | jq -r '.[]')
MGMT_CLUSTER_NAME=$(cd "$TF_INFRA" && $TERRAFORM output -raw management_cluster_name)
MGMT_CLUSTER_LOCATION=$(cd "$TF_INFRA" && $TERRAFORM output -raw management_cluster_location)

# Cloud Build SA permissions, granted up-front so all subsequent build submits
# have what they need. Newer projects use <num>-compute@developer for builds;
# older projects use <num>@cloudbuild. Grant both. roles/editor on the compute
# SA technically covers AR writer but isn't reliable in policy-restricted
# projects, so we set it explicitly.
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
CB_SAS=(
  "${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
  "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
)
for cb_sa in "${CB_SAS[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$cb_sa" --role=roles/artifactregistry.writer \
    --condition=None >/dev/null 2>&1 || true
  gcloud storage buckets add-iam-policy-binding "gs://$MODEL_WEIGHTS_BUCKET" \
    --member="serviceAccount:$cb_sa" --role=roles/storage.objectAdmin \
    >/dev/null 2>&1 || true
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. Image builds (parallel where deps allow)
# ─────────────────────────────────────────────────────────────────────────────

if [ "$SKIP_IMAGE_BUILDS" = "1" ]; then
  step "Skipping image builds (SKIP_IMAGE_BUILDS=1)"
  KUEUE_PID="" ; DISPATCHER_PID="" ; VLLM_PID=""
else

step "Building images via Cloud Build"

submit_build() {
  local label=$1
  local config=$2
  shift 2
  local extra_subs=("$@")
  local subs=""
  if [ ${#extra_subs[@]} -gt 0 ]; then
    subs="--substitutions=$(IFS=,; echo "${extra_subs[*]}")"
  fi
  echo "  → submitting $label"
  local logfile; logfile=$(mktemp -t install-build-$label-XXXX.log)
  if gcloud builds submit "${@:$#}" --no-source --project="$PROJECT_ID" --config="$config" $subs >"$logfile" 2>&1; then
    ok "$label build complete"
  else
    cat "$logfile"
    die "$label build failed"
  fi
}

# gcp-auth-plugin first — kueue-with-gcp-auth FROMs it.
echo "  → gcp-auth-plugin (clones public source)"
gcloud builds submit --no-source --project="$PROJECT_ID" \
  --config "$TF_KUEUE/docker/gcp-auth-plugin/cloudbuild.yaml" \
  --substitutions=_LOCATION=$REGION 2>&1 | tail -3
ok "gcp-auth-plugin built"

# kueue-with-gcp-auth, dispatcher, vllm in parallel (they're independent given gcp-auth-plugin is done).
echo "  → kueue-with-gcp-auth, dispatcher, vllm in parallel"
{
  cd "$TF_KUEUE" && \
  gcloud builds submit . --project="$PROJECT_ID" \
    --config docker/kueue-with-gcp-auth/cloudbuild.yaml \
    --substitutions=_KUEUE_VERSION=v$KUEUE_TAG,_TAG=$KUEUE_TAG,_AUTH_PLUGIN_IMAGE=$GCP_AUTH_PLUGIN_IMAGE \
    >/tmp/install-build-kueue.log 2>&1
} &
KUEUE_PID=$!

{
  cd "$ROOT_DIR" && \
  gcloud builds submit dispatcher --project="$PROJECT_ID" \
    --config 2-multikueue/docker/dispatcher/cloudbuild.yaml \
    --substitutions=_TAG=latest \
    >/tmp/install-build-dispatcher.log 2>&1
} &
DISPATCHER_PID=$!

{
  cd "$ROOT_DIR" && \
  gcloud builds submit . --project="$PROJECT_ID" \
    --config 3-multi-cluster-inference-gateway/docker/vllm/cloudbuild.yaml \
    --substitutions=_TAG=latest \
    >/tmp/install-build-vllm.log 2>&1
} &
VLLM_PID=$!

fi  # SKIP_IMAGE_BUILDS

# ─────────────────────────────────────────────────────────────────────────────
# 4. Weights uploader (parallel with image builds)
# ─────────────────────────────────────────────────────────────────────────────

if [ "$SKIP_WEIGHTS_UPLOAD" = "1" ]; then
  step "Skipping weights upload (SKIP_WEIGHTS_UPLOAD=1)"
  WEIGHTS_PID=""
else

step "Uploading Llama 3.1 8B weights to gs://$MODEL_WEIGHTS_BUCKET"

# Stash HF token in Secret Manager so Cloud Build can read it.
if ! gcloud secrets describe hf-token --project="$PROJECT_ID" >/dev/null 2>&1; then
  printf "%s" "$HF_TOKEN" | gcloud secrets create hf-token --project="$PROJECT_ID" --data-file=-
else
  printf "%s" "$HF_TOKEN" | gcloud secrets versions add hf-token --project="$PROJECT_ID" --data-file=-
fi

# Grant the Cloud Build SAs read access to the freshly-created hf-token Secret.
# (artifactregistry.writer + storage.objectAdmin were granted earlier, before
# the image builds; CB_SAS / PROJECT_NUMBER are still in scope.)
for cb_sa in "${CB_SAS[@]}"; do
  gcloud secrets add-iam-policy-binding hf-token --project="$PROJECT_ID" \
    --member="serviceAccount:$cb_sa" --role=roles/secretmanager.secretAccessor \
    --condition=None >/dev/null 2>&1 || true
done

# Run the upload (slow — ~10-15 min). Run in parallel with the image builds.
{
  gcloud builds submit --no-source --project="$PROJECT_ID" \
    --config "$TF_MCIG/docker/weights-uploader/cloudbuild.yaml" \
    --substitutions="_BUCKET_NAME=$MODEL_WEIGHTS_BUCKET" \
    >/tmp/install-build-weights.log 2>&1
} &
WEIGHTS_PID=$!

fi  # SKIP_WEIGHTS_UPLOAD

# Wait for parallel jobs; surface logs on failure.
fail=0
for spec in "kueue:$KUEUE_PID" "dispatcher:$DISPATCHER_PID" "vllm:$VLLM_PID" "weights:$WEIGHTS_PID"; do
  name=${spec%%:*}; pid=${spec##*:}
  [ -z "$pid" ] && continue
  if wait "$pid"; then
    ok "$name complete"
  else
    warn "$name failed; log: /tmp/install-build-$name.log"
    tail -30 /tmp/install-build-$name.log
    fail=1
  fi
done
[ $fail -eq 0 ] || die "One or more parallel builds failed"

# ─────────────────────────────────────────────────────────────────────────────
# 5. terraform apply 2-multikueue
# ─────────────────────────────────────────────────────────────────────────────

step "2-multikueue (Kueue + JobSet + LWS + dispatcher)"

cat > "$TF_KUEUE/terraform.tfvars" <<EOF
# Generated by scripts/install.sh — do not commit.
project_id = "$PROJECT_ID"
region     = "$REGION"

kueue_manager_image_repository = "$KUEUE_IMAGE"
kueue_manager_image_tag        = "$KUEUE_TAG"
dispatcher_image               = "$DISPATCHER_IMAGE"
gcp_auth_plugin_image          = "$GCP_AUTH_PLUGIN_IMAGE"
EOF

(cd "$TF_KUEUE" && $TERRAFORM init -input=false -upgrade) >/dev/null
(cd "$TF_KUEUE" && $TERRAFORM apply -input=false -auto-approve)

ok "2-multikueue applied"

# ─────────────────────────────────────────────────────────────────────────────
# 6. terraform apply 3-multi-cluster-inference-gateway
# ─────────────────────────────────────────────────────────────────────────────

step "3-multi-cluster-inference-gateway (gateway + EPP + InferencePool + vLLM)"

{
  echo "# Generated by scripts/install.sh — do not commit."
  echo "project_id = \"$PROJECT_ID\""
  echo "region     = \"$REGION\""
  echo ""
  echo "vllm_image         = \"$VLLM_IMAGE\""
  echo "model_weights_path = \"$MODEL_WEIGHTS_PATH\""
  [ -n "${ENABLE_POD_SNAPSHOT:-}" ]            && echo "enable_pod_snapshot = $ENABLE_POD_SNAPSHOT"
} > "$TF_MCIG/terraform.tfvars"

(cd "$TF_MCIG" && $TERRAFORM init -input=false -upgrade) >/dev/null
TF_VAR_hf_token="$HF_TOKEN" \
  $TERRAFORM -chdir="$TF_MCIG" apply -input=false -auto-approve

ok "3-mcig applied"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Rename kubectl contexts to demo-script-friendly aliases
# ─────────────────────────────────────────────────────────────────────────────

step "Setting up kubectl contexts (mgmt, worker-east1, worker-west3, ...)"

gcloud container clusters get-credentials "$MGMT_CLUSTER_NAME" \
  --region "$MGMT_CLUSTER_LOCATION" --project "$PROJECT_ID" >/dev/null 2>&1

src_ctx="gke_${PROJECT_ID}_${MGMT_CLUSTER_LOCATION}_${MGMT_CLUSTER_NAME}"
kubectl config delete-context mgmt 2>/dev/null || true
kubectl config rename-context "$src_ctx" mgmt
ok "mgmt context"

for cluster_name in "${WORKER_CLUSTER_NAMES[@]}"; do
  # ai-worker-us-east1 → location us-east1, alias worker-east1.
  region="us-${cluster_name##*-}"
  alias="worker-${cluster_name##*-}"
  gcloud container clusters get-credentials "$cluster_name" \
    --region "$region" --project "$PROJECT_ID" >/dev/null 2>&1
  src="gke_${PROJECT_ID}_${region}_${cluster_name}"
  kubectl config delete-context "$alias" 2>/dev/null || true
  kubectl config rename-context "$src" "$alias"
  ok "$alias context"
done

# ─────────────────────────────────────────────────────────────────────────────
# 8. Done
# ─────────────────────────────────────────────────────────────────────────────

step "Install complete"
echo ""
echo "  Inference clusters: ${WORKER_CLUSTER_NAMES[*]}"
echo "  Mgmt cluster:       $MGMT_CLUSTER_NAME ($MGMT_CLUSTER_LOCATION)"
echo "  vLLM image:         $VLLM_IMAGE"
echo "  Model weights:      $MODEL_WEIGHTS_PATH"
echo ""

if [ "$SKIP_DEMO" = "1" ]; then
  echo "Skipping demo-preemption.sh (SKIP_DEMO=1). Run manually:"
  echo "  ./demo-preemption.sh"
else
  echo "Running demo-preemption.sh..."
  exec "$ROOT_DIR/demo-preemption.sh"
fi
