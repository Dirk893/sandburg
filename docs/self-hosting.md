# Running Sandburg yourself

The Sandburg also runs without RunPod and Tailscale, with Docker and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html), either on your own machine or on a server, reached through an SSH tunnel or directly inside a private network (intranet or VPN). All of them use `docker-compose.yml` from this repository.

- [On your own machine](#on-your-own-machine)
- [On a server through an SSH tunnel](#on-a-server-through-an-ssh-tunnel)
- [On a server in a private network](#on-a-server-in-a-private-network)
- [Switching the plugin](#switching-the-plugin)

## On your own machine

```bash
cp .env.example .env      # leave TS_AUTHKEY empty, set SANDBURG_TOKEN
docker compose pull       # prebuilt image from ghcr.io/trn84/sandburg:latest
docker compose up -d
# MCP:     http://localhost:9090/<service>/mcp
# Files:   http://localhost:8090                 (user sandburg, password = token)
# Desktop: http://localhost:6080/vnc.html
# ComfyUI: http://localhost:8188
# OpenCode: http://localhost:4096                (with ENABLE_OPENCODE=1, user opencode)
```

To build the image yourself instead, run `docker compose up -d --build`. Run `pull` explicitly when you want the GHCR image: if the image is missing locally, `up` builds it instead of pulling it. Set `SANDBURG_IMAGE` in `.env` to use a different image or tag.

`docker compose up` reads `.env` through `env_file`, with or without `-d`. After changing `.env`, run `docker compose up -d` again, which recreates the container. `docker compose restart` keeps the old values. Logs: `docker compose logs -f`.

By default the ports are only published on `127.0.0.1` (see [On a server in a private network](#on-a-server-in-a-private-network) to change that), and the volume is the `workspace/` folder next to `docker-compose.yml`.

The GPUs are passed in through [CDI](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html) (`nvidia.com/gpu=all`). This needs Docker 25 or newer and the CDI spec of the NVIDIA Container Toolkit, which recent versions generate on their own: `nvidia-ctk cdi list` should list `nvidia.com/gpu=all`, otherwise create it with `sudo nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml`. With the older `driver: nvidia` reservation, a host with cgroup v2 and the systemd cgroup driver takes the GPU away from the container on every `systemctl daemon-reload` (e.g. after package updates), and Blender, ComfyUI and `nvidia-smi` then fail with `Failed to initialize NVML: Unknown Error`. CDI avoids that. If the driver is updated, the spec has to be regenerated.

## On a server through an SSH tunnel

On a GPU server you can reach over SSH, start the container exactly as [on your own machine](#on-your-own-machine), with the repository and `.env` on the server. The ports stay on the server's `127.0.0.1`, and an SSH tunnel forwards them to your machine:

```bash
ssh -N -L 9090:127.0.0.1:9090 -L 8090:127.0.0.1:8090 \
       -L 6080:127.0.0.1:6080 -L 8188:127.0.0.1:8188 -L 4096:127.0.0.1:4096 user@server
```

Or once in `~/.ssh/config`, then `ssh -N sandburg-server`:

```
Host sandburg-server
    HostName server.example.com
    User user
    LocalForward 9090 127.0.0.1:9090
    LocalForward 8090 127.0.0.1:8090
    LocalForward 6080 127.0.0.1:6080
    LocalForward 8188 127.0.0.1:8188
    LocalForward 4096 127.0.0.1:4096
```

While the tunnel is open, everything is reachable at the same `localhost` addresses as with a local container. Only 9090 (MCP) and 8090 (files) are needed for Claude Code. 6080 and 8188 are for the desktop and the ComfyUI web UI in your browser, 4096 for OpenCode.

The address in the plugin is therefore `127.0.0.1`, but the token is the **server's**: `SANDBURG_TOKEN` from the `.env` on the server, or `workspace/.sandburg-token` there if you left it empty. The token in a `.env` on your own machine does not apply. With the wrong token, all MCP servers fail with HTTP 401. To read it on the server:

```bash
ssh sandburg-server 'cd sandburg && grep "^SANDBURG_TOKEN=" .env || cat workspace/.sandburg-token'
```

## On a server in a private network

If your machine can reach the server directly, e.g. because the server is in an institute's intranet and you dial into it via VPN, you can skip the tunnel and publish the ports on the server's intranet address. In the `.env` on the server:

```bash
PUBLISH_ADDR=10.8.0.5           # the server's intranet IP; 0.0.0.0 = all interfaces
# COMFYUI_PUBLISH_ADDR=10.8.0.5  # optional, see below
```

Then `docker compose up -d`, and everything is reachable at `http://10.8.0.5:9090/...`, `:8090`, `:6080/vnc.html` and `:4096`. `PUBLISH_ADDR` covers MCP, files, noVNC and OpenCode, which are protected by `SANDBURG_TOKEN`, the VNC password and the OpenCode password. Everyone in that network can reach these ports, in an institute's intranet possibly thousands of people, so use a long `SANDBURG_TOKEN`. The connection is plain HTTP: the VPN encrypts the way from your machine into the intranet, but not inside it. The VNC password is limited to 8 characters by VNC itself.

ComfyUI (8188) stays on `127.0.0.1` unless you also set `COMFYUI_PUBLISH_ADDR`. It has no authentication: anyone who reaches the port can run workflows and install custom nodes, i.e. run code in the container. Claude Code doesn't need the port (it talks to ComfyUI through MCP), only the web UI in your browser does. Set it only in a small network where you trust everyone, otherwise forward just that port with `ssh -N -L 8188:127.0.0.1:8188 user@server`.

If the server has a firewall (e.g. `ufw`), note that Docker publishes ports past it through its own iptables rules. Binding to the intranet IP instead of `0.0.0.0` is what keeps the ports off a public interface.

In the plugin, the address is then the server's intranet IP (or a hostname that resolves to it) and the token is the server's.

## Switching the plugin

Under `/plugin` → **Installed** → *sandburg* → **Configure options** (or `/plugin configure sandburg@sandburg`), enter:

| | Address | Token |
|---|---|---|
| Pod | its Tailscale name (`TS_HOSTNAME`, default `sandburg`) | the pod's token (`SANDBURG_TOKEN` on RunPod, or `/workspace/.sandburg-token` on the pod) |
| Local container | `127.0.0.1` | `SANDBURG_TOKEN` from your `.env` (or `workspace/.sandburg-token` if you left it empty) |
| Server through an SSH tunnel | `127.0.0.1` | `SANDBURG_TOKEN` from the server's `.env` (or `workspace/.sandburg-token` on the server) |
| Server in a private network | the server's intranet IP (`PUBLISH_ADDR`) | same as through an SSH tunnel |

In the VS Code extension, `/plugin` is not available. There, set the values in a terminal instead, e.g. for the local container (run in the repository, takes the token from `.env`):

```bash
printf '{"host":"127.0.0.1","token":"%s"}' "$(grep '^SANDBURG_TOKEN=' .env | cut -d= -f2-)" |
    claude plugin configure sandburg@sandburg --values-stdin
```

and back to the pod with `{"host":"sandburg","token":"<the pod's token>"}`.

Then start a new Claude Code session. The MCP servers connect with the new values, and the `sandburg` command only picks them up at session start. If you use the same `SANDBURG_TOKEN` everywhere, only the address changes when you switch.
