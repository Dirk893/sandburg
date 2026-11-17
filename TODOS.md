# TODOs

Ideas for future versions of the Sandburg. Nothing here is planned in detail yet; the notes collect what we already know about each idea.

## Self-hosted WireGuard instead of Tailscale

Reach the Sandburg without a Tailscale account, through a WireGuard network you run yourself.

- **The pod has no `/dev/net/tun`** on RunPod and most GPU clouds, so neither kernel WireGuard nor `wireguard-go` works there. The tunnel has to run in userspace, as Tailscale does today (`--tun=userspace-networking` in `start-tailscale.sh`).
- **The pod can't accept incoming connections**, so it has to dial out to a hub with a public IP (a small VPS), and your machine connects to the same hub.
- Options:
  - [Headscale](https://github.com/juanfont/headscale) as a self-hosted Tailscale control server. This needs the least change: `tailscale up --login-server=<url>`, e.g. via a new `TS_LOGIN_SERVER` variable. Keeps MagicDNS, ACLs and ephemeral nodes.
  - Plain WireGuard with [wireproxy](https://github.com/pufferffish/wireproxy): a userspace WireGuard client that can publish selected local ports into the WireGuard network (`[TCPServerTunnel]`). New variables such as `WG_PRIVATE_KEY`, `WG_ADDRESS`, `WG_PEER_PUBLIC_KEY`, `WG_ENDPOINT`.
- **Plus for security:** with wireproxy only explicitly listed ports (9090, 8090, optionally 6080 and 8188) are reachable. Tailscale in userspace mode forwards every local port, including the unauthenticated Blender (9876) and FreeCAD (9875) bridges (see *Security* in the README).
- Document the hub setup (VPS, `wg0.conf`, keys) and the client side. The plugin's `host` then becomes the WireGuard IP of the pod.
- `start-tailscale.sh` and `start-wireguard.sh` should exclude each other; pick one via e.g. `NETWORK=tailscale|headscale|wireguard|none`.

## OpenCode: what is still open

OpenCode already runs on the pod as a web UI (`ENABLE_OPENCODE=1`, see the README). Still open:

- **Test with real models:** which models (via OpenRouter, local) cope with the Blender/FreeCAD/KiCad tools, whether tool results with images reach the model, and whether long tool calls (renders, 15–30 minutes) run through with the configured timeouts.
- **Ollama on your own machine:** in userspace mode, Tailscale does not route the pod's outgoing connections into the tailnet. `tailscaled --outbound-http-proxy-listen=127.0.0.1:1055` plus `HTTP_PROXY` for OpenCode (with `NO_PROXY=127.0.0.1,localhost` for the MCP proxy) should make a local Ollama reachable through its 100.x IP. Check whether Bun's fetch honors `HTTP_PROXY`, and whether internet traffic still goes out directly through the proxy.
- **An LLM on the pod's GPU** (vLLM or Ollama as an optional service, `ENABLE_LLM=1`), preconfigured as a provider in OpenCode, so the whole setup works without any cloud LLM. GPU memory has to be shared with ComfyUI, Blender and Voice.
- **OpenCode locally as a client** (like the Claude Code plugin): generate an `opencode.json` with `"type": "remote"` entries for `http://sandburg:9090/<service>/mcp` and `{env:SANDBURG_TOKEN}`, plus `sandburg get/put` for files, and the skill as `AGENTS.md`.
- **Keep the instructions in one place:** `rootfs/opt/sandburg/opencode/AGENTS.md` duplicates most of `plugin/skills/sandburg/SKILL.md`. Generate both from shared parts.
- **New MCP config format:** newer OpenCode versions have `mcp.servers` with separate `startup`/`catalog`/`execution` timeouts and mark the old format as deprecated. Switch over once the pinned version supports it.

## More cloud providers than RunPod

The image itself is provider-neutral; what is RunPod-specific is mostly the documentation (template fields, secrets, volume at `/workspace`).

- Candidates: [Vast.ai](https://vast.ai), [Lambda](https://lambda.ai), [Paperspace](https://www.paperspace.com), [Hetzner GPU servers](https://www.hetzner.com/dedicated-rootserver/matrix-gpu/), plain VMs on AWS, GCP or Azure with Docker and the NVIDIA Container Toolkit.
- Per provider, check and document:
  - how a container is started from `ghcr.io/<user>/sandburg:latest` (template, CLI, API) and how environment variables and secrets are passed
  - where the persistent volume is mounted; `WORKSPACE` can already be overridden in `common.sh`, but the README and plugin assume `/workspace`
  - container disk size limits (the image is about 11 GB, plus about 9 GB for PyTorch on the volume)
  - whether the container receives `SIGTERM` on stop, which the clean Tailscale logout relies on
  - whether `/dev/net/tun` exists (it would allow kernel networking, but userspace mode must keep working)
- On full VMs (Hetzner, AWS, GCP) `docker compose` from the repository is enough. Add a short guide and possibly a cloud-init file that installs Docker, the NVIDIA toolkit and starts the Sandburg.
- Restructure the README: a provider-neutral setup plus one short section (or file under `docs/providers/`) per provider.
- Later maybe a `sandburg up --provider <name>` command that starts and stops pods via the provider APIs, so you only pay while you work.
