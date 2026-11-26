import { createServer } from 'node:http';
import { createHandler } from './app.ts';
import { loadConfig } from './config.ts';
import { makeCtx } from './context.ts';
import { openDb } from './db.ts';
import { startBackups } from './backup.ts';
import { startDigests } from './services/digest.ts';
import { startRateRefresh } from './services/fx.ts';

const config = loadConfig();
const db = openDb(config.dbPath);
const ctx = makeCtx(db, config);

startBackups(db, config.backupDir, config.backupKeep ?? 14, (m) => console.log(m));

startRateRefresh(ctx, (m) => console.log(m));

startDigests(ctx, (m) => console.log(m));

const handle = createHandler(ctx);
const server = createServer((req, res) => {
  handle(req, res).catch((err) => {
    console.error('Request failed', err);
    res.destroy();
  });
});
server.requestTimeout = 60_000;
server.headersTimeout = 15_000;
server.keepAliveTimeout = 5_000;

server.listen(config.port, config.host, () => {
  console.log(`TIM-POS server listening on ${config.host}:${config.port}`);
});

function shutdown(): void {
  console.log('Shutting down');
  server.close(() => {
    db.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
