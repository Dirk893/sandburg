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
# Without it OpenCode would generate a new password on every start. OpenCode
# reads it from OPENCODE_PASSWORD and keeps it out of the agent's shell.
[ -n "${OPENCODE_PASSWORD}" ] || { log "ERROR: empty OpenCode password"; exit 1; }
export OPENCODE_PASSWORD

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
# Starting and listing tools gets two minutes: services such as Blender load
# their bridge on the first connection. With Code Mode (OpenCode's default) the
# model doesn't get a few hundred tool definitions up front.
config=/run/sandburg/opencode.json
jq '{
    "$schema": "https://opencode.ai/config.json",
    update: "disable",
    share: "disabled",
    snapshots: false,
    instructions: ["/opt/sandburg/opencode/AGENTS.md"],
    mcp: {
        timeout: {startup: 120000, catalog: 120000},
        servers: (.mcpServers
            | with_entries(select(.value.command != "/usr/local/bin/sandburg-disabled-mcp"))
            | with_entries(.value = {
                type: "remote",
                url: "http://127.0.0.1:9090/\(.key)/mcp",
                headers: {Authorization: "Bearer {env:SANDBURG_TOKEN}"},
                oauth: false,
                timeout: {execution: ((.value.timeout // "10m") | if endswith("m") then (rtrimstr("m") | tonumber * 60000) else 600000 end)}
            }))
    }
}' /run/sandburg/mcp-proxy.json > "${config}"
export OPENCODE_CONFIG="${config}"
log "MCP servers: $(jq -r '.mcp.servers | keys | join(" ")' "${config}")"

# OpenCode connects to the MCP servers once at startup.
wait_for_port 9090 120 || log "WARNING: MCP proxy not reachable on port 9090 – the tools will be missing"

cd "${WORKSPACE}/projects"
# OpenCode identifies a project by the first commit of its git repository, so
# give /workspace/projects one. The server runs in it, which makes it the
# server's default location. Snapshots are off (above), so OpenCode doesn't
# copy renders and ComfyUI output into git before every step.
if ! git rev-parse --verify -q HEAD > /dev/null 2>&1; then
    [ -d .git ] || git init -q
    git -c user.name=Sandburg -c user.email=sandburg@localhost \
        commit -q --allow-empty -m "Sandburg projects"
    log "Initialized ${WORKSPACE}/projects as a git repository for OpenCode"
fi

# "serve" runs OpenCode's server, including its web UI, in the foreground
# instead of as a background service. It only listens locally; the proxy in
# front of it (proxy.mjs) takes port 4096 and adds /files/ for images in the
# chat. Password-protected, but it gives a shell on the pod, so the proxy
# follows UI_BIND_ADDR (local only by default; Tailscale forwards to 127.0.0.1
# anyway).
/usr/local/bin/opencode serve --hostname 127.0.0.1 --port 4097 &
opencode_pid=$!
PROXY_HOST="${UI_BIND_ADDR:-127.0.0.1}" PROXY_PORT=4096 UPSTREAM_PORT=4097 \
    FILES_ROOT="${WORKSPACE}/projects" node /opt/sandburg/opencode/proxy.mjs &
proxy_pid=$!

# supervisord stops the whole process group; if one of the two exits on its
# own, stop the other too so supervisord restarts both.
trap 'kill -TERM "${opencode_pid}" "${proxy_pid}" 2> /dev/null; wait' TERM INT
wait -n "${opencode_pid}" "${proxy_pid}" || true
log "OpenCode or its proxy exited – restarting both"
kill -TERM "${opencode_pid}" "${proxy_pid}" 2> /dev/null || true
wait || true
exit 1
