const http = require("http");
const net = require("net");

const JARVIS_PORT = 8765;
const OBS_PORT = 3101;
const LISTEN_PORT = 3102;

function proxyRequest(req, res, targetPort) {
  const opts = {
    hostname: "127.0.0.1",
    port: targetPort,
    path: req.url,
    method: req.method,
    headers: req.headers,
  };
  const proxy = http.request(opts, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });
  proxy.on("error", () => {
    res.writeHead(502);
    res.end("Bad Gateway");
  });
  req.pipe(proxy);
}

const server = http.createServer((req, res) => {
  const target = req.url.startsWith("/ws") || req.url.startsWith("/health")
    ? JARVIS_PORT : OBS_PORT;
  proxyRequest(req, res, target);
});

server.on("upgrade", (req, socket, head) => {
  const targetPort = JARVIS_PORT;
  const opts = {
    hostname: "127.0.0.1",
    port: targetPort,
    path: req.url,
    method: "GET",
    headers: req.headers,
  };
  const proxy = http.request(opts);
  proxy.on("upgrade", (proxyRes, proxySocket, proxyHead) => {
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\n` +
      Object.entries(proxyRes.headers)
        .map(([k, v]) => `${k}: ${v}`)
        .join("\r\n") +
      "\r\n\r\n"
    );
    if (proxyHead.length) socket.write(proxyHead);
    proxySocket.pipe(socket);
    socket.pipe(proxySocket);
    proxySocket.on("error", () => socket.destroy());
    socket.on("error", () => proxySocket.destroy());
  });
  proxy.on("error", () => socket.destroy());
  proxy.end();
});

server.listen(LISTEN_PORT, "127.0.0.1", () => {
  console.log(`Proxy on :${LISTEN_PORT} → jarvis:${JARVIS_PORT} / obs:${OBS_PORT}`);
});
