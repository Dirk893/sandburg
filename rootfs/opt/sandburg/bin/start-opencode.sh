#!/usr/bin/env bash
# OpenCode web UI: a coding agent in the browser that works directly on the pod,
# with all enabled MCP servers preconfigured and any LLM provider (OpenRouter,
# OpenAI, Anthropic, an OpenAI-compatible endpoint …).
set -euo pipefail
LOG_TAG=opencode
# shellcheck source=common.sh
source /opt/sandburg/bin/common.sh
enabled ENABLE_OPENCODE || idle "OpenCode disabled (ENABLE_OPENCODE=0)"

# --- Password (HTTP basic auth, user "opencode") -----------------------------
pw_file="${WORKSPACE}/.opencode-password"
if [ -z "${OPENCODE_PASSWORD:-}" ]; then
    if [ -s "${pw_file}" ]; then
        OPENCODE_PASSWORD="$(< "${pw_file}")"
    else
        OPENCODE_PASSWORD="$(openssl rand -hex 16)"
        (umask 077 && printf '%s' "${OPENCODE_PASSWORD}" > "${pw_file}")
        log "Generated OpenCode password: ${pw_file}"
    fi
fi
# Without it OpenCode would run without any authentication.
[ -n "${OPENCODE_PASSWORD}" ] || { log "ERROR: empty OpenCode password"; exit 1; }
export OPENCODE_SERVER_PASSWORD="${OPENCODE_PASSWORD}"
unset OPENCODE_PASSWORD

# --- Sessions, API keys and settings on the volume ---------------------------
# Linked instead of changing XDG_* so the programs the agent starts from its
# shell (Blender, comfy-cli …) still find their own configuration in ~/.config.
state="${WORKSPACE}/.sandburg/opencode"
for pair in config:.config data:.local/share state:.local/state cache:.cache; do
    target="${state}/${pair%%:*}"
    link="${HOME:-/root}/${pair#*:}/opencode"
    mkdir -p "${target}" "$(dirname "${link}")"
    [ -L "${link}" ] || rm -rf "${link}"
    ln -sfn "${target}" "${link}"
done

# --- Config: the enabled MCP servers from the proxy config -------------------
# The token is not written into the file; OpenCode substitutes {env:…} itself.
# The tool timeout follows the proxy's timeout for the service ("15m" -> ms).
config=/run/sandburg/opencode.json
jq '{
    "$schema": "https://opencode.ai/config.json",
    autoupdate: false,
    share: "disabled",
    instructions: ["/opt/sandburg/opencode/AGENTS.md"],
    mcp: (.mcpServers
        | with_entries(select(.value.command != "/usr/local/bin/sandburg-disabled-mcp"))
        | with_entries(.value = {
            type: "remote",
            url: "http://127.0.0.1:9090/\(.key)/mcp",
            headers: {Authorization: "Bearer {env:SANDBURG_TOKEN}"},
            oauth: false,
            timeout: ((.value.timeout // "10m") | if endswith("m") then (rtrimstr("m") | tonumber * 60000) else 600000 end)
        }))
}' /run/sandburg/mcp-proxy.json > "${config}"
export OPENCODE_CONFIG="${config}"
log "MCP servers: $(jq -r '.mcp | keys | join(" ")' "${config}")"

# OpenCode connects to the MCP servers once at startup.
wait_for_port 9090 120 || log "WARNING: MCP proxy not reachable on port 9090 – the tools will be missing"

cd "${WORKSPACE}/projects"
# "serve" serves the same web UI as "web" without trying to open a browser.
# Password-protected, but it gives a shell on the pod, so it follows UI_BIND_ADDR
# (local only by default; Tailscale forwards to 127.0.0.1 anyway).
exec /usr/local/bin/opencode serve --hostname "${UI_BIND_ADDR:-127.0.0.1}" --port 4096
