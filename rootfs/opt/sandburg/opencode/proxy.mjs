// Small reverse proxy in front of the OpenCode web UI (port 4096 -> OpenCode on
// 127.0.0.1:4097). It adds one thing OpenCode can't do itself:
//  - /files/<path> serves files from /workspace/projects on the same origin, so
//    the agent can show plots and renders in the chat as Markdown images
//    (OpenCode's CSP only allows images from its own origin, https: and data:).
// Everything else, including SSE and WebSockets, goes through unchanged, and
// OpenCode checks the login itself. For /files the proxy asks OpenCode whether
// the request is logged in (password, session cookie or token), so both accept
// the same logins.
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";

const LISTEN_HOST = process.env.PROXY_HOST || "127.0.0.1";
const LISTEN_PORT = Number(process.env.PROXY_PORT || 4096);
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT || 4097);
const ROOT = path.resolve(process.env.FILES_ROOT || "/workspace/projects");

const TYPES = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".webp": "image/webp", ".svg": "image/svg+xml", ".bmp": "image/bmp",
    ".mp4": "video/mp4", ".webm": "video/webm", ".wav": "audio/wav", ".mp3": "audio/mpeg",
    ".pdf": "application/pdf", ".txt": "text/plain; charset=utf-8", ".csv": "text/plain; charset=utf-8",
};

// Resolves to the status of an authenticated OpenCode endpoint for the
// request's credentials: 200 = logged in, 401 = not.
function checkLogin(req) {
    const headers = {};
    for (const h of ["authorization", "cookie", "host", "origin"]) {
        if (req.headers[h] !== undefined) headers[h] = req.headers[h];
    }
    return new Promise((resolve) => {
        const up = http.request(
            { host: "127.0.0.1", port: UPSTREAM_PORT, method: "GET", path: "/api/info", headers },
            (upRes) => {
                upRes.resume();
                resolve(upRes.statusCode);
            },
        );
        up.setTimeout(10000, () => up.destroy());
        up.on("error", () => resolve(502));
        up.end();
    });
}

async function serveFile(req, res, urlPath) {
    const status = await checkLogin(req);
    if (status !== 200) {
        if (status === 401) {
            res.writeHead(401, { "WWW-Authenticate": 'Basic realm="Secure Area"' });
        } else {
            res.writeHead(502);
        }
        return res.end();
    }
    let rel;
    try {
        rel = decodeURIComponent(urlPath.slice("/files/".length));
    } catch {
        res.writeHead(400);
        return res.end();
    }
    const file = path.resolve(ROOT, rel);
    // Stay inside ROOT and keep hidden files (.git …) hidden, like the file server
    if (!file.startsWith(ROOT + path.sep) || path.relative(ROOT, file).split(path.sep).some((p) => p.startsWith("."))) {
        res.writeHead(404);
        return res.end();
    }
    fs.stat(file, (err, st) => {
        if (err || !st.isFile()) {
            res.writeHead(404);
            return res.end();
        }
        const type = TYPES[path.extname(file).toLowerCase()];
        const headers = {
            "Content-Type": type || "application/octet-stream",
            "Content-Length": st.size,
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff",
            // An SVG opened directly must not run scripts on this origin
            "Content-Security-Policy": "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox",
        };
        if (!type) headers["Content-Disposition"] = `attachment; filename="${path.basename(file).replace(/"/g, "")}"`;
        res.writeHead(200, headers);
        if (req.method === "HEAD") return res.end();
        fs.createReadStream(file).pipe(res);
    });
}

function proxy(req, res) {
    const up = http.request(
        { host: "127.0.0.1", port: UPSTREAM_PORT, method: req.method, path: req.url, headers: req.headers },
        (upRes) => {
            res.writeHead(upRes.statusCode, upRes.headers);
            upRes.pipe(res);
        },
    );
    up.on("error", () => {
        if (!res.headersSent) res.writeHead(502);
        res.end();
    });
    req.pipe(up);
}

const server = http.createServer((req, res) => {
    const urlPath = req.url.split("?")[0];
    if ((req.method === "GET" || req.method === "HEAD") && urlPath.startsWith("/files/")) {
        return serveFile(req, res, urlPath);
    }
    proxy(req, res);
});

// WebSockets (OpenCode's terminal): pass the raw connection through
server.on("upgrade", (req, socket, head) => {
    const up = net.connect(UPSTREAM_PORT, "127.0.0.1", () => {
        let raw = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
        for (let i = 0; i < req.rawHeaders.length; i += 2) raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
        up.write(raw + "\r\n");
        if (head && head.length) up.write(head);
        up.pipe(socket).pipe(up);
    });
    up.on("error", () => socket.destroy());
    socket.on("error", () => up.destroy());
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
    console.log(`proxy on http://${LISTEN_HOST}:${LISTEN_PORT} -> 127.0.0.1:${UPSTREAM_PORT}, /files/ -> ${ROOT}`);
});
