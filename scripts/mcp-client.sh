#!/bin/bash
# Fetches an Auth0 Client Credentials token and launches supergateway with it.
# Used as the Claude Code MCP server command for end-to-end JWT demo.

set -euo pipefail

TOKEN=$(curl -sf -X POST "https://${AUTH0_DOMAIN}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${AUTH0_CLIENT_ID}&client_secret=${AUTH0_CLIENT_SECRET}&audience=${AUTH0_AUDIENCE}" \
  | jq -r .access_token)

exec npx -y supergateway \
  --streamableHttp "${MCP_ENDPOINT}" \
  --header "Authorization: Bearer ${TOKEN}"
