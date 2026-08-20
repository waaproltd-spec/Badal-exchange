import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../lib/asyncHandler';
import { requireAuth, requireRole } from '../auth/middleware';
import { moneyLimiter } from '../auth/rateLimit';
import { requireIdempotencyKey } from '../lib/idempotency';
import { writeAudit } from '../lib/audit';
import {
  cashdeskBotDeposit,
  cashdeskBotPayout,
  cashdeskBotBalance,
  cashdeskBotSearchUser,
} from '../services/cashdeskBotService';

/**
 * Admin-only. The mobile apps never call CashdeskBot directly and never
 * see these credentials -- they talk to Badal Exchange's backend, which
 * holds the CashdeskBot login/cashierpass/hash/cashdeskid as server-side
 * environment variables and does all signing here.
 */
export const cashdeskBotRouter = Router();
cashdeskBotRouter.use(requireAuth, requireRole('admin'));

const depositSchema = z.object({
  lng: z.string().min(1),
  summa: z.number().positive(),
});

const payoutSchema = z.object({
  lng: z.string().min(1),
  code: z.string().min(1),
});

cashdeskBotRouter.post(
  '/deposit/:userId',
  moneyLimiter,
  requireIdempotencyKey('cashdeskbot.deposit'),
  asyncHandler(async (req, res) => {
    const input = depositSchema.parse(req.body);
    const result = await cashdeskBotDeposit(req.params.userId, input);
    await writeAudit({
      actorId: req.user!.id,
      actorRole: 'admin',
      action: 'cashdeskbot.deposit',
      entityType: 'cashdeskbot_user',
      entityId: req.params.userId,
      after: { lng: input.lng, summa: input.summa },
      ip: req.ip,
    });
    res.json(result);
  })
);

cashdeskBotRouter.post(
  '/payout/:userId',
  moneyLimiter,
  requireIdempotencyKey('cashdeskbot.payout'),
  asyncHandler(async (req, res) => {
    const input = payoutSchema.parse(req.body);
    const result = await cashdeskBotPayout(req.params.userId, input);
    await writeAudit({
      actorId: req.user!.id,
      actorRole: 'admin',
      action: 'cashdeskbot.payout',
      entityType: 'cashdeskbot_user',
      entityId: req.params.userId,
      after: result,
      ip: req.ip,
    });
    // success:false is a real, non-exceptional outcome (e.g. insufficient
    // balance) -- returned as-is with HTTP 200 so the admin dashboard can
    // show CashdeskBot's own message rather than a generic error.
    res.json(result);
  })
);

cashdeskBotRouter.get(
  '/balance',
  asyncHandler(async (req, res) => {
    const dt = req.query.dt ? new Date(String(req.query.dt)) : undefined;
    if (dt && Number.isNaN(dt.getTime())) {
      return res.status(400).json({ error: { code: 'BAD_REQUEST', message: 'Invalid dt' } });
    }
    const result = await cashdeskBotBalance(dt);
    res.json(result);
  })
);

cashdeskBotRouter.get(
  '/users/:userId',
  asyncHandler(async (req, res) => {
    const result = await cashdeskBotSearchUser(req.params.userId);
    res.json(result);
  })
);
