# MCP on Kubernetes with agentgateway + JWT Auth

This project demonstrates a local, production-inspired MCP (Model Context Protocol) security pattern:

> Protect an MCP server behind **agentgateway**, require a valid OAuth/JWT access token, and keep the OAuth client secret out of the MCP host configuration file.

In this setup:

- An MCP server (`@modelcontextprotocol/server-everything`) runs inside a local **minikube** Kubernetes cluster.
- **agentgateway** acts as an MCP-aware gateway in front of the server.
- **Claude Code** acts as the MCP host.
- A local wrapper script retrieves the Auth0 client secret from the **macOS Keychain** at runtime.
- The MCP launcher exchanges the client credentials for a short-lived Auth0 access token.
- **supergateway** bridges Claude Code's stdio MCP connection to the HTTP MCP endpoint exposed through agentgateway.
- agentgateway validates the JWT before forwarding MCP traffic to the backend MCP server.

The result: the MCP server is not directly exposed as an unauthenticated tool endpoint. Requests must pass through the gateway with a valid bearer token before reaching the MCP server.

> This is a headless machine-to-machine pattern. It authenticates the MCP host/application, not an individual end user.

---

## What This Demonstrates

This project is useful for learning how to:

- Put a gateway enforcement point in front of an MCP server.
- Use OAuth 2.0 client credentials for headless MCP access.
- Validate JWTs at agentgateway before proxying MCP traffic.
- Keep client secrets out of `.mcp.json` by retrieving them from macOS Keychain at runtime.
- Run an HTTP-based MCP server behind Kubernetes Gateway API resources.
- Bridge a local stdio MCP host to an HTTP MCP endpoint using `supergateway`.

## What This Does Not Demonstrate

This is intentionally scoped. It does **not** demonstrate:

- Per-user delegated authorization.
- User identity passthrough.
- End-user consent flows.
- Production-grade secret rotation.
- Enterprise managed identity or workload identity.
- Full MCP policy enforcement, such as per-tool authorization or data loss prevention.
- Remote JWKS fetching in agentgateway v1.1.0 for Auth0 over an ExternalName Service.

For production, prefer workload identity, managed identity, or `private_key_jwt` where possible instead of a long-lived client secret.

---

## Architecture

```mermaid
sequenceDiagram
    participant CC as Claude Code<br/>(MCP host)
    participant W as mcp-client-auth0-wrapper.zsh
    participant KC as macOS Keychain
    participant S as mcp-client.sh
    participant A0 as Auth0 Token Endpoint
    participant SG as supergateway<br/>(stdio-to-HTTP bridge)
    participant AG as agentgateway<br/>(Kubernetes)
    participant MS as mcp-server-everything<br/>(Kubernetes)

    CC->>W: Spawn configured MCP server command
    W->>KC: Read client_secret using AUTH0_SECRET_NAME
    KC-->>W: client_secret
    W->>S: exec mcp-client.sh<br/>(AUTH0_CLIENT_SECRET in env)

    S->>A0: POST /oauth/token<br/>grant_type=client_credentials
    A0-->>S: access_token JWT

    S->>SG: exec supergateway --streamableHttp MCP_ENDPOINT<br/>--header "Authorization: Bearer <token>"

    loop MCP calls
        CC->>SG: JSON-RPC over stdio
        SG->>AG: POST /mcp<br/>Authorization: Bearer <JWT>
        Note over AG: JWKS loaded from inline jwt-policy.yaml<br/>Remote JWKS scaffold included for future use
        AG->>AG: Verify JWT signature, issuer, audience, expiry
        alt JWT valid
            AG->>MS: Forward MCP request
            MS-->>AG: MCP result
            AG-->>SG: 200 OK + result
            SG-->>CC: JSON-RPC response
        else JWT invalid or missing
            AG-->>SG: 401 authentication failure
            SG-->>CC: error
        end
    end
```

---

## Prerequisites

| Tool | Version used | Install |
|------|-------------|---------|
| Docker Desktop | 28.x+ | https://docs.docker.com/get-docker/ |
| minikube | 1.38.x+ | https://minikube.sigs.k8s.io/docs/start/ |
| kubectl | 1.36.x+ | https://kubernetes.io/docs/tasks/tools/ |
| helm | 4.x+ | https://helm.sh/docs/intro/install/ |
| Node.js + npx | 22.x+ | https://nodejs.org/ |
| jq | current | `brew install jq` |
| Auth0 account | free tier is sufficient | https://auth0.com |

> **macOS only:** this repo stores the Auth0 client secret in the macOS Keychain. The wrapper script uses the `security` CLI, which ships with macOS.

---

## Project Structure

```text
.
|-- README.md
|-- .mcp.json                            # Claude Code MCP server config
|-- config/
|   `-- claude_desktop_config.json       # Claude Desktop MCP config, no-auth variant
|-- scripts/
|   |-- mcp-client-auth0-wrapper.zsh     # Reads secret from Keychain, execs mcp-client.sh
|   `-- mcp-client.sh                    # Fetches Auth0 JWT, launches supergateway
`-- k8s/
    |-- mcp-server/
    |   |-- deployment.yaml              # MCP server pod using node:22-alpine + mcp-proxy
    |   `-- service.yaml                 # ClusterIP with appProtocol: agentgateway.dev/mcp
    `-- agentgateway/
        |-- gateway.yaml                 # Gateway listener on port 80
        |-- backend.yaml                 # AgentgatewayBackend selecting the MCP service
        |-- httproute.yaml               # HTTPRoute wiring Gateway -> Backend
        |-- jwt-policy.yaml              # AgentgatewayPolicy enforcing JWT in Strict mode
        `-- auth0-jwks-service.yaml      # ExternalName Service scaffold for future remote JWKS use
```

---

## Step 1 - Auth0 Setup

### 1.1 Create an API

In the Auth0 dashboard, create a new **API**:

| Field | Value |
|---|---|
| Name | `MCP Gateway` |
| Identifier / Audience | `https://mcp.gateway` |
| Signing Algorithm | RS256 |

### 1.2 Create a Machine-to-Machine Application

Create a new **Machine to Machine** application and authorize it against the API you just created.

Note down:

- **Domain** - for example, `your-tenant.us.auth0.com`
- **Client ID**
- **Client Secret**

### 1.3 Copy your JWKS

This project uses inline JWKS in `jwt-policy.yaml`.

Fetch your Auth0 JWKS:

```bash
curl -s "https://<your-domain>/.well-known/jwks.json"
```

Save the JSON output. You will paste it into `jwt-policy.yaml` in Step 5.

---

## Step 2 - Store the Client Secret in macOS Keychain

The client secret is **not stored in `.mcp.json`**. The wrapper script retrieves it at runtime using the macOS `security` CLI.

Run this once:

```bash
security add-generic-password \
  -a "$USER" \
  -s auth0-mcp-client-secret \
  -w "YOUR_CLIENT_SECRET_HERE" \
  -U
```

- `-s` sets the service name. This must match `AUTH0_SECRET_NAME` in `.mcp.json`.
- `-a` sets the account to your macOS username.
- `-w` sets the secret value.
- `-U` updates the existing Keychain item if it already exists.

To verify it was stored:

```bash
security find-generic-password \
  -a "$USER" \
  -s auth0-mcp-client-secret \
  -w
```

---

## Step 3 - Start minikube

```bash
minikube start --driver=docker --cpus=4 --memory=4096
```

---

## Step 4 - Install agentgateway

```bash
# Kubernetes Gateway API CRDs
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# agentgateway CRDs
helm upgrade -i --create-namespace \
  --namespace agentgateway-system \
  --version v1.1.0 \
  agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

# agentgateway control plane
helm upgrade -i \
  -n agentgateway-system \
  --version v1.1.0 \
  agentgateway oci://cr.agentgateway.dev/charts/agentgateway

# Verify all pods reach Running
kubectl get pods -n agentgateway-system
```

---

## Step 5 - Apply Kubernetes Manifests

### 5.1 MCP Server Deployment

`k8s/mcp-server/deployment.yaml` runs the reference MCP server inside the cluster using `mcp-proxy` to expose it over HTTP:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-everything
  namespace: agentgateway-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-server-everything
  template:
    metadata:
      labels:
        app: mcp-server-everything
    spec:
      containers:
      - name: mcp-server
        image: node:22-alpine
        command: ["npx", "-y", "mcp-proxy", "--port", "8080", "--", "npx", "-y", "@modelcontextprotocol/server-everything"]
        ports:
        - containerPort: 8080
```

`k8s/mcp-server/service.yaml` exposes it as a ClusterIP Service. The `appProtocol: agentgateway.dev/mcp` value identifies the Service as an MCP endpoint for agentgateway:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mcp-server-everything
  namespace: agentgateway-system
  labels:
    app: mcp-server-everything
spec:
  selector:
    app: mcp-server-everything
  ports:
  - port: 80
    targetPort: 8080
    appProtocol: agentgateway.dev/mcp
```

### 5.2 agentgateway Resources

`k8s/agentgateway/gateway.yaml` - HTTP listener on port 80:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
```

`k8s/agentgateway/backend.yaml` - selects the MCP service by metadata label:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: mcp-server-everything
      selector:
        services:
          matchLabels:
            app: mcp-server-everything
```

`k8s/agentgateway/httproute.yaml` - routes traffic through the gateway to the MCP backend:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
  - backendRefs:
    - name: mcp-backend
      namespace: agentgateway-system
      group: agentgateway.dev
      kind: AgentgatewayBackend
```

`k8s/agentgateway/jwt-policy.yaml` - enforces JWT authentication in **Strict** mode.

Update `issuer`, `audiences`, and `jwks.inline` to match your Auth0 tenant and API:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: jwt-auth-policy
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
      - issuer: "https://<your-auth0-domain>/"
        audiences:
        - "https://mcp.gateway"
        jwks:
          inline: '<paste your JWKS JSON here>'
```

> **Why inline JWKS?**
> For this local PoC, inline JWKS is the most reliable option. The `remote` JWKS approach requires agentgateway to fetch keys from an external HTTPS endpoint. With agentgateway v1.1.0, this did not work reliably through an ExternalName Service for Auth0 because TLS origination to the external HTTPS endpoint was not available in this setup.
>
> This means signing keys only need to be updated when Auth0 rotates them. For a future production-style version, revisit remote JWKS support or use an in-cluster identity provider such as Keycloak.

`k8s/agentgateway/auth0-jwks-service.yaml` - scaffold for remote JWKS, not active in the current configuration:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: auth0-jwks
  namespace: agentgateway-system
spec:
  type: ExternalName
  externalName: <your-tenant>.us.auth0.com
  ports:
  - port: 443
    targetPort: 443
```

Apply all manifests:

```bash
kubectl apply -f k8s/mcp-server/
kubectl apply -f k8s/agentgateway/

kubectl rollout status deployment/mcp-server-everything \
  -n agentgateway-system
```

---

## Step 6 - Expose agentgateway Locally

Run this in a dedicated terminal and keep it open for the duration of your session:

```bash
kubectl port-forward deployment/agentgateway-proxy \
  -n agentgateway-system 8080:80
```

The MCP endpoint is now reachable locally at:

```text
http://localhost:8080/mcp
```

---

## Step 7 - Configure the MCP Host

### Claude Code

`.mcp.json` configures Claude Code to launch the Auth0 wrapper as the MCP server command.

Fill in your Auth0 values. Do **not** put the client secret in this file.

```json
{
  "mcpServers": {
    "everything": {
      "command": "/path/to/scripts/mcp-client-auth0-wrapper.zsh",
      "env": {
        "AUTH0_DOMAIN": "<your-tenant>.us.auth0.com",
        "AUTH0_CLIENT_ID": "<your-client-id>",
        "AUTH0_AUDIENCE": "https://mcp.gateway",
        "AUTH0_SECRET_NAME": "auth0-mcp-client-secret",
        "MCP_ENDPOINT": "http://localhost:8080/mcp"
      }
    }
  }
}
```

### Claude Desktop, no-auth variant

`config/claude_desktop_config.json` is a simpler Claude Desktop config that skips Auth0. Use this only while JWT policy is disabled or before applying the JWT policy.

```json
{
  "mcpServers": {
    "everything": {
      "command": "npx",
      "args": ["-y", "supergateway", "--streamableHttp", "http://localhost:8080/mcp"]
    }
  }
}
```

Copy this file to:

```text
~/Library/Application Support/Claude/claude_desktop_config.json
```

Then fully quit and relaunch Claude Desktop.

---

## How the Auth Flow Works

The auth launcher uses two scripts.

### `scripts/mcp-client-auth0-wrapper.zsh`

This script retrieves the Auth0 client secret from macOS Keychain and then execs the next stage.

```zsh
#!/bin/zsh
emulate -L zsh
set -euo pipefail

: "${AUTH0_DOMAIN:?Missing AUTH0_DOMAIN}"
: "${AUTH0_CLIENT_ID:?Missing AUTH0_CLIENT_ID}"
: "${AUTH0_AUDIENCE:?Missing AUTH0_AUDIENCE}"
: "${MCP_ENDPOINT:?Missing MCP_ENDPOINT}"
: "${AUTH0_SECRET_NAME:?Missing AUTH0_SECRET_NAME}"

AUTH0_CLIENT_SECRET="$(
  security find-generic-password \
    -a "$USER" \
    -s "$AUTH0_SECRET_NAME" \
    -w
)"

export AUTH0_CLIENT_SECRET

exec /path/to/scripts/mcp-client.sh
```

### `scripts/mcp-client.sh`

This script exchanges the client credentials for a short-lived Auth0 JWT, then starts `supergateway`.

```bash
#!/bin/bash
set -euo pipefail

TOKEN="$(curl -sf -X POST "https://${AUTH0_DOMAIN}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${AUTH0_CLIENT_ID}&client_secret=${AUTH0_CLIENT_SECRET}&audience=${AUTH0_AUDIENCE}" \
  | jq -r .access_token)"

exec npx -y supergateway \
  --streamableHttp "${MCP_ENDPOINT}" \
  --header "Authorization: Bearer ${TOKEN}"
```

> The token is acquired when the MCP process starts. For long-running sessions, add token renewal logic or restart the MCP process when the token expires.

---

## Step 8 - Validate

### 8.1 Confirm a valid token is accepted

Fetch a token from Auth0 and use it in a request:

```bash
TOKEN="$(curl -sf -X POST "https://<your-domain>/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<your-client-id>&client_secret=<your-client-secret>&audience=https://mcp.gateway" \
  | jq -r .access_token)"

curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

Expected result:

- HTTP `200`
- an `Mcp-Session-Id` response header
- an MCP initialize result
- no `authentication failure` in the body

### 8.2 Confirm a bad token is rejected

Malformed JWT:

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer invalid.jwt.token" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"test"}}}'
```

Expected:

```text
authentication failure: the token header is malformed
```

Structurally valid JWT with unknown key ID:

```bash
HEADER="$(echo -n '{"alg":"RS256","typ":"JWT","kid":"fake-key-id"}' | base64 | tr '+/' '-_' | tr -d '=')"
PAYLOAD="$(echo -n '{"sub":"test","iss":"https://<your-domain>/","aud":"https://mcp.gateway","exp":9999999999}' | base64 | tr '+/' '-_' | tr -d '=')"
SIG="ZmFrZXNpZ25hdHVyZQ"

curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${HEADER}.${PAYLOAD}.${SIG}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"test"}}}'
```

Expected:

```text
authentication failure: token uses the unknown key "fake-key-id"
```

---

## Security Notes

This repo demonstrates a useful gateway pattern, but there are important boundaries:

- **Client credentials is application identity.** The gateway authenticates the MCP host/application, not the individual user.
- **The client secret still exists at runtime.** Keychain keeps it out of `.mcp.json` and out of the repo, but the wrapper exports it to the child process so `mcp-client.sh` can request a token.
- **The JWT should be short-lived.** Do not rely on a long-lived bearer token.
- **Validate audience and issuer.** The token should be issued by the expected Auth0 tenant and intended for the MCP gateway audience.
- **Do not expose this over plain HTTP in production.** This demo uses local `kubectl port-forward` and `localhost`.
- **Add policy for real use.** JWT validation is only the first layer. Real deployments should also consider per-client authorization, per-tool authorization, logging, rate limiting, egress controls, and data handling policies.

---

## Troubleshooting

### `mcp: no backends configured`

The `AgentgatewayBackend` selector matches Service **metadata labels**, not just `spec.selector`.

Verify the Service has the expected label:

```bash
kubectl get svc mcp-server-everything \
  -n agentgateway-system \
  --show-labels
```

### MCP server pod not starting

```bash
kubectl describe pod -l app=mcp-server-everything \
  -n agentgateway-system

kubectl logs deployment/mcp-server-everything \
  -n agentgateway-system
```

### Keychain secret not found

```bash
security find-generic-password \
  -a "$USER" \
  -s auth0-mcp-client-secret \
  -w
```

If it returns nothing, repeat Step 2.

### Port already in use

```bash
lsof -ti:8080 | xargs kill
```

### Teardown

```bash
helm uninstall agentgateway agentgateway-crds \
  -n agentgateway-system

kubectl delete namespace agentgateway-system

minikube delete
```