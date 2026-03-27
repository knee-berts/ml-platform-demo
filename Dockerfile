# ============================================================
# vLLM on NVIDIA RTX PRO 6000 Blackwell (sm_120 / CC 12.0)
# Supports: LoRA, prefix caching / KV-cache routing, OpenAI API
# Base: Official vLLM OpenAI server image (CUDA 13.0, sm_120 built in)
#
# NOTE: Building vLLM from source inside NGC 25.05 (PyTorch 2.8) fails due to
# a missing torch/headeronly/util/Float8_e4m3fnuz.h header in that release.
# The official vllm/vllm-openai image ships with sm_120 CUDA kernels precompiled
# and is the supported path for Blackwell.
# ============================================================
# syntax=docker/dockerfile:1

ARG VLLM_TAG=latest
FROM vllm/vllm-openai:${VLLM_TAG}

# ── Labels ────────────────────────────────────────────────────
LABEL maintainer="your-team@example.com" \
      description="vLLM inference server for NVIDIA RTX PRO 6000 Blackwell (sm_120)" \
      cuda="13.0+" \
      vllm="latest"

# ── Install FlashInfer with Blackwell support ─────────────────
# FlashInfer is the fastest attention backend on Blackwell (sm_120).
# Try cu128 wheels first (matches vLLM image's CUDA 12.8-built torch),
# fall back to source install if the pre-built wheel isn't available.
RUN pip install --no-cache-dir flashinfer-python \
        --find-links https://flashinfer.ai/whl/cu128/torch2.7/ \
    || pip install --no-cache-dir flashinfer-python \
        --find-links https://flashinfer.ai/whl/cu130/torch2.7/ \
    || pip install --no-cache-dir flashinfer-python

# ── Blackwell runtime environment ─────────────────────────────
ENV \
    # FlashInfer is the fastest attention backend on Blackwell (sm_120).
    VLLM_ATTENTION_BACKEND=FLASHINFER \
    # Flash Attention v2 is stable on Blackwell; FA3 is still maturing.
    VLLM_FLASH_ATTN_VERSION=2 \
    # Required for prefix caching / chunked prefill; also forces V1 engine
    # on since LoRA disables auto-detection in some vLLM builds.
    VLLM_USE_V1=1 \
    # Expandable segments reduce VRAM fragmentation on 96 GB Blackwell.
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    HF_HOME=/workspace/hf_cache \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN mkdir -p /workspace/hf_cache /workspace/models

# ── Expose OpenAI-compatible API port ─────────────────────────
EXPOSE 8000

# ── Health check ──────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# ── Default entrypoint: OpenAI-compatible API server ──────────
# All runtime flags (--model, --enable-lora, etc.) are passed at deploy time.
ENTRYPOINT ["python3", "-m", "vllm.entrypoints.openai.api_server"]
CMD ["--help"]
