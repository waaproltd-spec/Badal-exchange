import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import { config } from './config';
import { apiLimiter } from './auth/rateLimit';
import { authRouter } from './routes/auth';
import { customerRouter } from './routes/customer';
import { agentRouter } from './routes/agent';
import { adminRouter } from './routes/admin';
import { cashdeskBotRouter } from './routes/cashdeskbot';
import { ApiError } from './lib/errors';

const app = express();

app.set('trust proxy', 1);
app.use(helmet());
app.use(
  cors({
    origin: [config.adminDashboardOrigin],
    credentials: true,
  })
);
app.use(express.json({ limit: '1mb' }));
app.use(apiLimiter);

app.get('/health', (_req, res) => res.json({ ok: true }));

app.use('/auth', authRouter);
app.use('/customer', customerRouter);
app.use('/agent', agentRouter);
app.use('/admin', adminRouter);
app.use('/admin/cashdeskbot', cashdeskBotRouter);

app.use((req, res) => {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: `No route for ${req.method} ${req.path}` } });
});

// Centralized error handler -- every route uses asyncHandler() so thrown
// errors (including zod validation errors) land here.
app.use((err: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  if (err instanceof ApiError) {
    return res.status(err.status).json({ error: { code: err.code, message: err.message, details: err.details } });
  }
  if (err && typeof err === 'object' && 'issues' in (err as any)) {
    // zod ZodError
    return res.status(400).json({ error: { code: 'VALIDATION_ERROR', message: 'Invalid request', details: (err as any).issues } });
  }
  console.error(err);
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
});

app.listen(config.port, () => {
  console.log(`Badal Exchange backend listening on :${config.port}`);
});

// Periodic MobCash automation sweep (deposit-feed poll + retry of any
// pending WinWin withdrawals). No-ops immediately unless an admin has
// explicitly turned automation_mode to 'automatic' -- see
// automationOrchestrator.ts.
const MOBCASH_SWEEP_INTERVAL_MS = 60_000;
setInterval(() => {
  import('./services/automationOrchestrator')
    .then((m) => m.runAutomationSweep())
    .catch((err) => console.error('MobCash automation sweep failed', err instanceof Error ? err.message : err));
}, MOBCASH_SWEEP_INTERVAL_MS);
