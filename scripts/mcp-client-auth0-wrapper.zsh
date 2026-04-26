#!/bin/zsh
emulate -L zsh
set -euo pipefail

# Required values supplied by mcpServers.json
: "${AUTH0_DOMAIN:?Missing AUTH0_DOMAIN}"
: "${AUTH0_CLIENT_ID:?Missing AUTH0_CLIENT_ID}"
: "${AUTH0_AUDIENCE:?Missing AUTH0_AUDIENCE}"
: "${MCP_ENDPOINT:?Missing MCP_ENDPOINT}"
: "${AUTH0_SECRET_NAME:?Missing AUTH0_SECRET_NAME}"

# Retrieve the client secret from macOS Keychain.
AUTH0_CLIENT_SECRET="$(
  security find-generic-password \
    -a "$USER" \
    -s "$AUTH0_SECRET_NAME" \
    -w
)"

# Make the secret available to the real MCP client process.
export AUTH0_CLIENT_SECRET

exec /Users/tony/Code/MCP/scripts/mcp-client.sh
