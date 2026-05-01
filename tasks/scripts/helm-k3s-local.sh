#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Local k3s for Helm / Skaffold workflows using k3d (macOS primary; Linux also supported).
# Requires Docker running. Writes merged kubeconfig to HELM_K3S_KUBECONFIG or $KUBECONFIG or ./kubeconfig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CLUSTER_NAME="${HELM_K3S_CLUSTER_NAME:-openshell-dev}"
# Host port forwarded to the chart's gateway NodePort (values.yaml service.nodePort).
GATEWAY_NODEPORT="${HELM_K3S_GATEWAY_NODEPORT:-30051}"
HOST_GATEWAY_PORT="${HELM_K3S_HOST_GATEWAY_PORT:-${GATEWAY_NODEPORT}}"

default_kubeconfig="${ROOT}/kubeconfig"
if [[ -n "${HELM_K3S_KUBECONFIG:-}" ]]; then
  KUBECONFIG_TARGET="${HELM_K3S_KUBECONFIG}"
elif [[ -n "${KUBECONFIG:-}" ]]; then
  # mise sets KUBECONFIG to a single file — use it when unambiguous
  if [[ "${KUBECONFIG}" != *:* ]]; then
    KUBECONFIG_TARGET="${KUBECONFIG}"
  else
    KUBECONFIG_TARGET="${default_kubeconfig}"
  fi
else
  KUBECONFIG_TARGET="${default_kubeconfig}"
fi

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <create|delete|start|stop|status>

Environment:
  HELM_K3S_CLUSTER_NAME       k3d cluster name (default: openshell-dev)
  HELM_K3S_KUBECONFIG         kubeconfig file to write/merge (default: repo kubeconfig or \$KUBECONFIG)
  HELM_K3S_GATEWAY_NODEPORT   Kubernetes NodePort for gateway (default: 30051, matches Helm chart)
  HELM_K3S_HOST_GATEWAY_PORT  Host port mapped to NodePort (default: same as NodePort)

macOS uses k3d (Docker required). Linux uses the same k3d flow when Docker is available.
Pair with: mise run helm:skaffold:dev
EOF
}

require_supported_os() {
  case "$(uname -s)" in
    Darwin | Linux) ;;
    *)
      echo "error: local k3s tasks are only supported on macOS and Linux." >&2
      exit 1
      ;;
  esac
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: Docker is required for k3d. Install Docker Desktop (macOS) or Docker Engine (Linux)." >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "error: Docker does not appear to be running." >&2
    exit 1
  fi
}

require_k3d() {
  if ! command -v k3d >/dev/null 2>&1; then
    echo "error: k3d not found. Run: mise install" >&2
    exit 1
  fi
}

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "error: kubectl not found. Run: mise install" >&2
    exit 1
  fi
}

k3d_context_name() {
  echo "k3d-${CLUSTER_NAME}"
}

k3d_cluster_exists() {
  k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1
}

merge_kubeconfig() {
  require_kubectl
  local tmp k3d_cfg merged_dir
  tmp="$(mktemp)"
  k3d kubeconfig get "${CLUSTER_NAME}" >"${tmp}"

  if [[ -s "${KUBECONFIG_TARGET}" ]]; then
    KUBECONFIG="${KUBECONFIG_TARGET}:${tmp}" kubectl config view --flatten >"${tmp}.out"
    mv "${tmp}.out" "${KUBECONFIG_TARGET}"
  else
    merged_dir="$(dirname "${KUBECONFIG_TARGET}")"
    mkdir -p "${merged_dir}"
    mv "${tmp}" "${KUBECONFIG_TARGET}"
  fi
  rm -f "${tmp}"

  kubectl --kubeconfig="${KUBECONFIG_TARGET}" config use-context "$(k3d_context_name)"
}

apply_base_manifests() {
  require_kubectl
  local manifest="${ROOT}/deploy/kube/manifests/agent-sandbox.yaml"
  echo "Applying agent-sandbox manifests..."
  kubectl --kubeconfig="${KUBECONFIG_TARGET}" apply -f "${manifest}"
}

configure_ghcr_credentials() {
  [[ -n "${GITHUB_PAT:-}" && -n "${GITHUB_USERNAME:-}" ]] || return 0

  echo "Configuring ghcr.io credentials on cluster nodes..."

  local registries_content
  registries_content="$(printf 'configs:\n  "ghcr.io":\n    auth:\n      username: %s\n      password: %s\n' \
    "${GITHUB_USERNAME}" "${GITHUB_PAT}")"

  local -a nodes
  mapfile -t nodes < <(docker ps --format '{{.Names}}' \
    --filter "name=k3d-${CLUSTER_NAME}-server" 2>/dev/null || true)

  if [[ ${#nodes[@]} -eq 0 ]]; then
    echo "warning: no server nodes found for cluster '${CLUSTER_NAME}', skipping ghcr.io credential setup." >&2
    return 0
  fi

  for node in "${nodes[@]}"; do
    printf '%s\n' "${registries_content}" \
      | docker exec -i "${node}" sh -c 'mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/registries.yaml'
    docker exec "${node}" kill -SIGHUP 1
    echo "  Configured ghcr.io credentials on ${node}"
  done
}

cmd_create() {
  require_supported_os
  require_docker
  require_k3d

  local port_map="${HOST_GATEWAY_PORT}:${GATEWAY_NODEPORT}@server:0"

  if k3d_cluster_exists; then
    echo "k3d cluster '${CLUSTER_NAME}' already exists; merging kubeconfig."
  else
    echo "Creating k3d cluster '${CLUSTER_NAME}' (maps host:${HOST_GATEWAY_PORT} -> NodePort ${GATEWAY_NODEPORT})..."
    k3d cluster create "${CLUSTER_NAME}" \
      --wait \
      --kubeconfig-update-default=false \
      --kubeconfig-switch-context=false \
      --port "${port_map}"
  fi
  merge_kubeconfig
  apply_base_manifests
  configure_ghcr_credentials
  echo "Active context: $(k3d_context_name)"
  echo "Kubeconfig: ${KUBECONFIG_TARGET}"
  echo "Gateway (when chart uses NodePort ${GATEWAY_NODEPORT}): http://127.0.0.1:${HOST_GATEWAY_PORT}"
}

cmd_delete() {
  require_supported_os
  require_k3d
  if k3d_cluster_exists; then
    k3d cluster delete "${CLUSTER_NAME}"
    echo "Deleted k3d cluster '${CLUSTER_NAME}'."
  else
    echo "No k3d cluster named '${CLUSTER_NAME}'."
  fi
}

cmd_start() {
  require_supported_os
  require_k3d
  k3d cluster start "${CLUSTER_NAME}"
}

cmd_stop() {
  require_supported_os
  require_k3d
  k3d cluster stop "${CLUSTER_NAME}"
}

cmd_status() {
  require_supported_os
  require_k3d
  k3d cluster list
}

main() {
  local sub="${1:-}"
  case "${sub}" in
    create) cmd_create ;;
    delete) cmd_delete ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    -h | --help | help | "") usage ; [[ -n "${sub}" ]] || exit 1 ;;
    *)
      echo "error: unknown command '${sub}'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
