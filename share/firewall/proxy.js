#!/usr/bin/env node
// proxy.js - minimal HTTPS allowlist proxy for the sandbox firewall.
//
// Usage: node proxy.js <port> <allowlist-file>
//
// Only CONNECT to port 443 is supported (HTTPS); plain HTTP requests are refused.
// The target host must be in the allowlist: one entry per line, "example.com" for
// an exact host or "*.example.com" for any subdomain. '#' starts a comment.
// The proxy resolves the host itself and refuses private/loopback/link-local
// addresses, so an allowed name can't be used to reach the host or LAN.
// Refused requests are logged as "DENY <host>" (read with `<runtime> logs`).

const http = require('http');
const net = require('net');
const dns = require('dns').promises;
const fs = require('fs');

const [port, allowFile] = process.argv.slice(2);

const exact = new Set();
const suffixes = [];
for (const raw of fs.readFileSync(allowFile, 'utf8').split('\n')) {
  const line = raw.replace(/#.*/, '').trim().toLowerCase();
  if (!line) continue;
  if (line.startsWith('*.')) suffixes.push(line.slice(1)); // ".example.com"
  else exact.add(line);
}

const isAllowed = (host) => exact.has(host) || suffixes.some((s) => host.endsWith(s));

function isPrivate(addr) {
  if (net.isIPv6(addr)) {
    const a = addr.toLowerCase();
    if (a.startsWith('::ffff:')) return isPrivate(a.slice(7));
    return a === '::' || a === '::1' || /^f[cd]/.test(a) || /^fe[89ab]/.test(a);
  }
  const [a, b] = addr.split('.').map(Number);
  return a === 0 || a === 10 || a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168);
}

function deny(client, host, why) {
  console.log(`DENY ${host}${why ? ` (${why})` : ''}`);
  client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
}

const server = http.createServer((req, res) => {
  console.log(`DENY ${req.url} (plain HTTP not supported)`);
  res.writeHead(403).end('HTTPS only\n');
});

server.on('connect', async (req, client, head) => {
  client.on('error', () => client.destroy());
  let url;
  try { url = new URL(`https://${req.url}`); } catch { return deny(client, req.url, 'bad target'); }
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (url.port && url.port !== '443') return deny(client, host, `port ${url.port}`);
  if (!isAllowed(host)) return deny(client, host);

  let address;
  try { ({ address } = await dns.lookup(host)); } catch { return deny(client, host, 'dns failure'); }
  if (isPrivate(address)) return deny(client, host, `private address ${address}`);

  const upstream = net.connect(443, address, () => {
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    upstream.write(head);
    upstream.pipe(client);
    client.pipe(upstream);
  });
  upstream.on('error', () => client.destroy());
  client.on('close', () => upstream.destroy());
});

server.listen(Number(port), '0.0.0.0', () => console.log(`listening on ${port}`));

// As PID 1 in the container node ignores SIGTERM by default, so `podman rm -f`
// would wait out its 10s stop timeout before killing us.
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => process.exit(0));

