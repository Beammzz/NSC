# syntax=docker/dockerfile:1

# SignMind Python gRPC inference service.
#
#   docker build -t signmind-inference Inference_backend/   # context is this dir
#
# The Go backend dials this service over gRPC (SIGNMIND_AI_ADDR) and there is no
# HTTP fallback on the landmark path, so the server is useless without it.

FROM python:3.12-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /app

# pyproject.toml deliberately omits the TFLite runtime from [project.dependencies]
# because neither ai-edge-litert nor tensorflow ships win_arm64 wheels, which the
# Windows dev setup needs (Inference_backend/AGENTS.md). A Linux container has no
# such constraint, so pin ai-edge-litert here — it is the interpreter engine.py
# prefers (default_interpreter_factory tries it before tensorflow.lite).
# Both linux/amd64 and linux/arm64 have manylinux wheels for this version.
ARG LITERT_VERSION=2.2.0

# Native libraries MediaPipe needs and python:3.12-slim does not ship. Each was
# found by running the extraction until it stopped failing, in this order:
#   libgl1, libglib2.0-0  cv2 (opencv-contrib-python, pulled in by mediapipe)
#   libegl1, libgles2     the GL context the vision tasks create per landmarker
# Miss any one and the service still starts and serves inference — extraction
# fails at the first call with "libXXX.so: cannot open shared object file".
# No GUI stack is installed: these are the headless runtime pieces only.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgl1 libglib2.0-0 libegl1 libgles2 \
 && rm -rf /var/lib/apt/lists/*

# Runtime deps are read straight out of pyproject.toml rather than restated, so
# this never drifts from the source of truth. The `extract` extra comes along:
# it is what lets this service answer ExtractKeypoints (the Go gateway image is
# a static binary with no Python, so extraction has to live here).
# tomllib is stdlib on 3.11+.
COPY pyproject.toml ./
RUN <<'PY' python3
import tomllib
with open("pyproject.toml", "rb") as f:
    project = tomllib.load(f)["project"]
deps = project["dependencies"] + project["optional-dependencies"]["extract"]
with open("/tmp/requirements.txt", "w") as f:
    f.write("\n".join(deps) + "\n")
print("resolved runtime deps:", deps)
PY
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
      "ai-edge-litert==${LITERT_VERSION}" \
 && rm -f /tmp/requirements.txt

# Layout matters: InferenceEngine() with no output_dir resolves its artifact dir
# as <parent of inference/>/TSL_Output (engine.py), so TSL_Output must sit beside
# the package. tsl_preprocess is a top-level module imported by both engine.py
# and server.py, so it lands at /app too.
COPY inference/ ./inference/
COPY tsl_preprocess.py ./
# extract_keypoints is likewise top-level: the ExtractKeypoints RPC imports it.
COPY extract_keypoints.py ./
# Baked in so the image runs standalone; mount a volume over /app/TSL_Output to
# persist models uploaded through the admin webui across restarts.
COPY TSL_Output/ ./TSL_Output/

# Fetch the two MediaPipe .task landmarker models (~16 MB) at build time.
# extract_keypoints downloads them into the cwd on first use otherwise, and by
# then the process is the unprivileged `signmind` user with a root-owned /app —
# the download would fail with EACCES on every extraction. Baking them in also
# keeps the running service off the network.
RUN python3 -c "import extract_keypoints; extract_keypoints._download_models_if_missing()"

RUN useradd --system --uid 10001 --shell /usr/sbin/nologin signmind \
 && chown -R signmind:signmind /app/TSL_Output
USER signmind

# 0.0.0.0 (not the localhost default) so the backend container can reach it.
# SIGNMIND_AI_SHARED_SECRET has no default on purpose: unset leaves this gRPC
# service UNAUTHENTICATED, and anyone who can reach the port could then replace
# the live model. server.py logs a warning; the compose file requires it.
ENV SIGNMIND_AI_ADDR=0.0.0.0:50051

EXPOSE 50051

# gRPC has no plain-HTTP endpoint to curl, so probe that the port accepts a TCP
# connection — enough to distinguish "serving" from "crashed or still loading".
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import socket;socket.create_connection(('127.0.0.1',50051),3).close()"]

ENTRYPOINT ["python", "-m", "inference.server"]
