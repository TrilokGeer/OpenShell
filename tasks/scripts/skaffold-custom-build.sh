#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Skaffold custom build: stage Linux prebuilt binaries, then docker-build the image.
# No `mise run` wrapper — uses stage-prebuilt-binaries.sh (cargo via mise x inside that script).

set -euo pipefail

TARGET=${1:?"usage: $0 <gateway|supervisor>"}
case "${TARGET}" in
  gateway | supervisor) ;;
  *)
    echo "error: target must be gateway or supervisor" >&2
    exit 1
    ;;
esac

if [[ -z "${IMAGE:-}" ]]; then
  echo "error: IMAGE must be set by Skaffold" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${ROOT}" ]]; then
  echo "error: could not resolve git repository root" >&2
  exit 1
fi
cd "${ROOT}"

# Stages deploy/docker/.build/prebuilt-binaries/<arch>/* (runs cargo via mise x -- in script).
bash tasks/scripts/stage-prebuilt-binaries.sh "${TARGET}"

dockerfile="deploy/docker/Dockerfile.images"
common_args=(-f "${dockerfile}" --target "${TARGET}" -t "${IMAGE}" .)

if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load --provenance=false "${common_args[@]}"
elif docker version >/dev/null 2>&1; then
  # Classic docker build may not accept --provenance (buildx-only).
  docker build "${common_args[@]}"
elif podman version >/dev/null 2>&1; then
  podman build "${common_args[@]}"
else
  echo "error: need docker (or buildx), or podman" >&2
  exit 1
fi
