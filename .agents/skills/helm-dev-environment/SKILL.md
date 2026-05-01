---
name: helm-dev-environment
description: Start up, tear down, and configure the local Kubernetes development environment for OpenShell. Uses k3d (Docker-backed k3s) + Skaffold + Helm. Covers cluster lifecycle, optional add-ons (Keycloak OIDC, Traefik Ingress, Envoy Gateway), and port mappings. Trigger keywords - local k8s, local cluster, k3d, skaffold, helm dev, start cluster, stop cluster, tear down cluster, delete cluster, create cluster, helm:k3s, helm:skaffold, local dev environment, dev cluster, k8s dev, envoy gateway local, keycloak local, traefik ingress local.
---

# Helm Dev Environment

Set up, run, and tear down the local Kubernetes development environment for OpenShell.
The stack is: **k3d** (Docker-backed k3s) for the cluster, **Skaffold** for image builds and Helm deploys, and the **OpenShell Helm chart** (`deploy/helm/openshell/`).

---

## Prerequisites

- Docker Desktop (macOS) or Docker Engine (Linux) running
- `mise install` completed (provides `k3d`, `kubectl`, `skaffold`, `helm`)

---

## Startup

### 1. Create the cluster

```bash
mise run helm:k3s:create
```

Creates a k3d cluster named `openshell-dev` and merges its kubeconfig. Also applies
base manifests (`deploy/kube/manifests/agent-sandbox.yaml`).

Port mappings created at cluster time (cannot be changed without recreating):

| Host port | Target | Used by |
|-----------|--------|---------|
| `30051` | NodePort `30051` on server node | OpenShell gateway (direct NodePort) |
| `8080` | Traefik `:80` via k3d load balancer | Traefik Ingress (`values-ingress.yaml`) |
| `30080` | NodePort `30080` on server node | Envoy Gateway proxy (`envoy-gateway-openshell.yaml`) |

Override any port with env vars before running `helm:k3s:create`:
- `HELM_K3S_HOST_GATEWAY_PORT` (default: `30051`)
- `HELM_K3S_INGRESS_HOST_PORT` (default: `8080`)
- `HELM_K3S_ENVOY_GATEWAY_PORT` (default: `30080`)

### 2. Deploy OpenShell

**Iterative dev** (rebuilds on file changes, recommended during active development):
```bash
mise run helm:skaffold:dev
```

**One-shot deploy** (build once and leave running):
```bash
mise run helm:skaffold:run
```

Both commands build the `gateway` and `supervisor` images from `deploy/docker/Dockerfile.dev`
and deploy the OpenShell Helm chart with cert-manager and Envoy Gateway.

After deploy, the gateway is reachable at `http://127.0.0.1:30051` (NodePort).

---

## Teardown

### Remove the Helm releases (keep cluster)

```bash
mise run helm:skaffold:delete
```

### Delete the cluster entirely

```bash
mise run helm:k3s:delete
```

This removes the k3d cluster and all resources. Kubeconfig context is left behind
but will point to a deleted cluster — safe to ignore or clean up manually.

---

## Optional Add-ons

Each add-on requires uncommenting the corresponding `valuesFiles` entry in
`deploy/helm/openshell/skaffold.yaml` before running `helm:skaffold:dev` or `helm:skaffold:run`.

### Traefik Ingress

k3s ships Traefik as its default ingress controller — no extra install needed.

1. Uncomment `#- values-ingress.yaml` in `skaffold.yaml`
2. Redeploy: `mise run helm:skaffold:run`
3. Access: `http://127.0.0.1:8080`

`values-ingress.yaml` enables the `networking.k8s.io/v1` Ingress resource with the
`traefik.ingress.kubernetes.io/service.serversscheme: h2c` annotation for gRPC cleartext.

### Envoy Gateway (Gateway API / HTTP CONNECT)

Envoy Gateway is already installed by Skaffold (the `envoy-gateway` Helm release in
`skaffold.yaml`). To activate routing and HTTP CONNECT tunneling:

1. Uncomment `#- values-gateway.yaml` in `skaffold.yaml`
2. Redeploy: `mise run helm:skaffold:run`
3. Apply the standalone manifests (GatewayClass, EnvoyProxy NodePort config, BackendTrafficPolicy):
   ```bash
   kubectl apply -f deploy/kube/manifests/envoy-gateway-openshell.yaml
   ```
4. Access: `http://127.0.0.1:30080`

The `EnvoyProxy` resource in the manifest pins the proxy Service to NodePort `30080`
to avoid a klipper-lb hostPort conflict with Traefik on single-node k3d clusters.

`values-gateway.yaml` creates a `Gateway` (listener on port 80, class `eg`) and a
`GRPCRoute` in the `openshell` namespace.

### Keycloak OIDC

One-time setup — only needed once per cluster lifetime:

```bash
mise run keycloak:k8s:setup
```

This deploys Keycloak (`quay.io/keycloak/keycloak:24.0`) into the `keycloak` namespace,
imports the openshell realm from `scripts/keycloak-realm.json`, and prints a port-forward
command for acquiring tokens from the CLI.

Then activate OIDC in the OpenShell Helm chart:
1. Uncomment `#- values-keycloak.yaml` in `skaffold.yaml`
2. Redeploy: `mise run helm:skaffold:run`

To remove Keycloak:
```bash
mise run keycloak:k8s:teardown
```

---

## Cluster Lifecycle (suspend/resume)

Stop the cluster without losing state (faster than delete/recreate):
```bash
mise run helm:k3s:stop
mise run helm:k3s:start
```

Check cluster status:
```bash
mise run helm:k3s:status
```

---

## Key Files

| Path | Purpose |
|------|---------|
| `deploy/helm/openshell/skaffold.yaml` | Skaffold config — images, Helm releases, values overlays |
| `deploy/helm/openshell/values.yaml` | Default Helm values |
| `deploy/helm/openshell/values-skaffold.yaml` | Dev overrides (image pull policy, local image names) |
| `deploy/helm/openshell/values-cert-manager.yaml` | cert-manager TLS overlay (always active in dev) |
| `deploy/helm/openshell/values-gateway.yaml` | Envoy Gateway HTTPRoute + Gateway overlay |
| `deploy/helm/openshell/values-ingress.yaml` | Traefik Ingress overlay |
| `deploy/helm/openshell/values-keycloak.yaml` | Keycloak OIDC overlay |
| `deploy/kube/manifests/envoy-gateway-openshell.yaml` | GatewayClass, EnvoyProxy, BackendTrafficPolicy |
| `tasks/scripts/helm-k3s-local.sh` | k3d cluster create/delete/start/stop/status |
| `tasks/scripts/keycloak-k8s-setup.sh` | Keycloak deploy + realm import |
