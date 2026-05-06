# Derived Kueue manager image with the gcp-auth-plugin baked in at
# /plugins/gcp-auth-plugin. Avoids the need for a kustomize postrender
# (which would require shelling out from Terraform — see ADR in 2-multikueue/README.md).
#
# Build:
#   docker build \
#     --build-arg KUEUE_VERSION=v0.15.1 \
#     --build-arg AUTH_PLUGIN_IMAGE=us-east1-docker.pkg.dev/<project>/gcp-auth-plugin/gcp-auth-plugin:v0.0.1 \
#     -t us-east1-docker.pkg.dev/<project>/vllm-blackwell/kueue-with-gcp-auth:0.15.1 .
#
# Or via Cloud Build:
#   gcloud builds submit --config docker/cloudbuild.yaml \
#     --substitutions=_KUEUE_VERSION=v0.15.1
#
# Then point terraform.tfvars at the resulting image:
#   kueue_manager_image_repository = "us-east1-docker.pkg.dev/<project>/vllm-blackwell/kueue-with-gcp-auth"
#   kueue_manager_image_tag        = "0.15.1"

ARG KUEUE_VERSION=v0.15.1
ARG AUTH_PLUGIN_IMAGE=us-east1-docker.pkg.dev/kubecon-fleets-demo-1/gcp-auth-plugin/gcp-auth-plugin:v0.0.1
ARG KUEUE_BASE_IMAGE=registry.k8s.io/kueue/kueue

# Source layer carrying the plugin binary at /gcp-auth-plugin.
FROM ${AUTH_PLUGIN_IMAGE} AS plugin

# Distroless Kueue manager image. COPY across stages still works even though
# we can't run shell commands here.
FROM ${KUEUE_BASE_IMAGE}:${KUEUE_VERSION}
COPY --from=plugin /gcp-auth-plugin /plugins/gcp-auth-plugin
