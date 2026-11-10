// Runs functions/dev-bot/index.ts outside Deno, for the test: a tiny Deno shim (env + serve) and a plain HTTP server.
// Started by dev_bot_function.test.mjs with `node --experimental-strip-types`.
import http from 'node:http';

const handlers = [];
globalThis.Deno = {
  env: { get: (k) => process.env[k] },
  serve: (h) => { handlers.push(h); },
};
await import('../functions/dev-bot/index.ts');
const handler = handlers[0];
http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (typeof v === 'string') headers.set(k, v);
  const r = await handler(new Request(`http://${req.headers.host}${req.url}`, { method: req.method, headers, body: req.method === 'GET' ? undefined : body }));
  res.writeHead(r.status, Object.fromEntries(r.headers));
  res.end(Buffer.from(await r.arrayBuffer()));
}).listen(Number(process.env.HARNESS_PORT), '127.0.0.1', () => console.log('ready'));
