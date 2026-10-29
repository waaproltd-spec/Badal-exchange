// Sahal (Golis) merchant transaction feed, stage 1: READ ONLY
// (migrations/*_merchant_feed.sql). Woken every minute by the database with
// the platform worker secret while the feed is not stopped.
//
// It talks to the merchant portal exactly as the portal's own web page does
// (mymerchant.golis.so, js/bundle.js): POST /api/account/login with
// {userNature, type, username, currency, password}; resultCode 2001 is
// signed in, 1001 / 6083 ask for a second code, 6054 for a new password;
// POST /api/account/transactions with {userNature, sessionId}; 4005 / 7777
// mean the session ended.
//
// Sahal answers 1001 and texts an access code to the merchant phone: the
// feed waits (needs_code) with Sahal's pending session until a manager
// types the code in the Agent App; it is then sent like the portal's
// "Authenticate" page does (POST /api/account/2auth {type, code, sessionId})
// and the session kept alive by reading every minute. Anything else stops
// the feed until a manager signs in again, so the merchant phone is never
// flooded with codes.
//
// The transactions are stored and matched by the database.
//
// With the session open, it then sends waiting Golis / ZAAD withdrawals
// (migrations/*_sahal_payouts.sql) the way the portal's Customer Fund
// Transfer page does (b2pfundTransferCtrl): POST /api/account/find
// {type: 'internetwork', mobileNo} for the receiver's name, then
// POST /api/money/b2p {receiverMobile, receiverName, pin, amount,
// description, isInterNetwork}; 2001 with transferInfo["Transfer-Id"] is
// sent. The database decides what may go (Off/Test/Live, daily limit, one
// attempt per withdrawal); anything unclear is reported as such and never
// sent again.
//
// Sahal ends the session it accepts transfers with (measured on 2026-10-29:
// about every 55 minutes; session log, diagnostics section 18) while
// the list still reads ("Session data is not found, please sign in again",
// ER0654). Then it signs in again at once by itself and the refused
// withdrawal goes out with the new session; when Sahal asks for its SMS code
// the old session keeps reading (deposits) until a manager has typed it
// (migrations/*_withdrawal_speed.sql), and the alert chat is told. While
// nothing waits, a receiver look-up (no money) checks the session, so a lost
// one is found before a customer waits.
//
// Secrets: GOLIS_MERCHANT_USERNAME, GOLIS_MERCHANT_PASSWORD
//          [, GOLIS_MERCHANT_PIN (the merchant PIN; no PIN, nothing is sent),
//           GOLIS_MERCHANT_CURRENCY (else the portal's USD entry), GOLIS_MERCHANT_BASE_URL,
//           GOLIS_MERCHANT_PROBE_MOBILE (the number looked up to check the
//           session; else the login, when it is a phone number)]
const PROVIDER = 'golis';
const BASE = (Deno.env.get('GOLIS_MERCHANT_BASE_URL') || 'https://mymerchant.golis.so').replace(/\/$/, '');

async function rpc(fn: string, args: Record<string, unknown>) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (!key.startsWith('sb_')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(args),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`${fn}: ${data?.message ?? res.status}`);
  return data;
}

// The portal's cookies, kept and sent back like a browser does.
const jar = new Map<string, string>();
const cookieHeader = () => [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
function keepCookies(res: Response) {
  for (const c of res.headers.getSetCookie?.() ?? []) {
    const [pair] = c.split(';');
    const i = pair.indexOf('=');
    if (i > 0) jar.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
  }
}
const saveCookies = () => rpc('merchant_feed_save_cookies', { p_provider: PROVIDER, p_cookies: cookieHeader() });

/** One line in the session log (start, loss, code, refusal; never a code, a
 *  password or a session id). Writing it can never break a run. */
const logEvent = (event: string, detail: Record<string, unknown> = {}) =>
  rpc('merchant_feed_log', { p_provider: PROVIDER, p_event: event, p_detail: detail }).catch(() => null);

/** The merchant login: the account a manager activated in the Admin
 *  Dashboard (Vault), else the function secrets this feed always used. If the
 *  database cannot be asked, the run fails and tries again: it never falls
 *  back to the old secrets while another account may be the active one. */
type Creds = { username: string | null; password: string | null; pin: string | null; currency: string | null };
let creds: Creds = { username: null, password: null, pin: null, currency: null };
async function loadCredentials(): Promise<Creds> {
  const c = await rpc('sahal_credentials', {});
  if (c?.username && c?.password) {
    return { username: String(c.username), password: String(c.password), pin: c.pin ? String(c.pin) : null, currency: c.currency ? String(c.currency) : null };
  }
  return {
    username: Deno.env.get('GOLIS_MERCHANT_USERNAME') ?? null,
    password: Deno.env.get('GOLIS_MERCHANT_PASSWORD') ?? null,
    pin: Deno.env.get('GOLIS_MERCHANT_PIN') ?? null,
    currency: Deno.env.get('GOLIS_MERCHANT_CURRENCY') ?? null,
  };
}

async function portal(path: string, body: Record<string, unknown>) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...(jar.size ? { Cookie: cookieHeader() } : {}) },
    body: JSON.stringify({ userNature: 'MERCHANT', ...body }),
    signal: AbortSignal.timeout(20_000),
  });
  keepCookies(res);
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${path}: HTTP ${res.status}, not JSON`);
  }
}

/** The arrays of objects in a reply, largest first (where the rows are). */
function rowArrays(data: unknown): Record<string, unknown>[][] {
  const found: Record<string, unknown>[][] = [];
  const walk = (v: unknown, depth: number) => {
    if (depth > 3 || v == null || typeof v !== 'object') return;
    if (Array.isArray(v)) {
      if (v.length > 0 && v.every((x) => x && typeof x === 'object' && !Array.isArray(x))) found.push(v as Record<string, unknown>[]);
      return;
    }
    for (const x of Object.values(v)) walk(x, depth + 1);
  };
  walk(data, 0);
  return found.sort((a, b) => b.length - a.length);
}

/** A reply's shape without its values: keys only, for the status message. */
const shape = (data: unknown) =>
  data && typeof data === 'object' ? Object.keys(data as object).slice(0, 20).join(',') : typeof data;

async function sha256(s: string) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** The portal's own id for a row, else a fingerprint of the whole row. */
async function rowId(row: Record<string, unknown>) {
  const key = Object.keys(row).find((k) => /^(transaction_?id|trans_?id|tran_?id|txn_?id|tid)$/i.test(k));
  const v = key ? String(row[key] ?? '').trim() : '';
  return v || `sha256:${await sha256(JSON.stringify(row))}`;
}

async function currency(): Promise<string> {
  const fixed = creds.currency;
  if (fixed) return fixed;
  // The page may load the list with GET; try POST first, then GET.
  let data = await portal('/api/account/currencies', {});
  if (rowArrays(data).length === 0) {
    const res = await fetch(`${BASE}/api/account/currencies`, {
      headers: { Accept: 'application/json', ...(jar.size ? { Cookie: cookieHeader() } : {}) },
      signal: AbortSignal.timeout(20_000),
    });
    keepCookies(res);
    data = await res.json().catch(() => data);
  }
  for (const rows of rowArrays(data)) {
    const usd = rows.find((c) => Object.values(c).some((v) => /^(usd|840|us)$/i.test(String(v ?? '').trim())));
    if (usd) {
      const code = usd.CURRENCYCODE ?? usd.currencyCode ?? usd.code;
      if (code != null) return String(code);
    }
  }
  throw new Error(`no USD entry in /api/account/currencies (reply: ${shape(data)}${(data as any)?.replyMessage ? ` \"${String((data as any).replyMessage).slice(0, 80)}\"` : ''})`);
}

const withIds = (rows: Record<string, unknown>[]) =>
  Promise.all(rows.map(async (r) => ({ ...r, _id: await rowId(r) })));

type Report = { state: string; code?: string | null; message?: string | null; session?: string | null; rows?: unknown[] };
const report = (r: Report) =>
  rpc('merchant_feed_report', {
    p_provider: PROVIDER,
    p_state: r.state,
    p_result_code: r.code ?? null,
    p_message: r.message ?? null,
    p_session_id: r.session ?? null,
    p_rows: r.rows ?? [],
  });

async function run() {
  creds = await loadCredentials();
  if (!creds.username || !creds.password) {
    return report({ state: 'not_configured', message: 'Set the Sahal merchant login in the Admin Dashboard (or GOLIS_MERCHANT_USERNAME and GOLIS_MERCHANT_PASSWORD)' });
  }
  const feed = await rpc('merchant_feed_get', { p_provider: PROVIDER });
  if (feed?.state === 'stopped' || feed?.state === 'needs_code') {
    // Waiting for a person; a kept session still reads Sahal's list.
    return feed?.readSessionId ? { readOnly: await readWithKeptSession(feed) } : { skipped: feed.state };
  }

  jar.clear();
  for (const part of String(feed?.cookies ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) jar.set(part.slice(0, i).trim(), part.slice(i + 1).trim());
  }
  let session: string | null = feed?.sessionId ?? null;
  let claimed = false;
  // Signed in during this run: what the old session was refused goes again now.
  let fresh = false;
  let firstRows: Record<string, unknown>[] = [];
  if (feed?.state === 'code_entered') {
    // The manager's access code, sent with Sahal's pending session (once).
    // Exactly one run gets it; any other run woken at the same time skips.
    const { secondSessionId, code } = await rpc('merchant_feed_take_code', { p_provider: PROVIDER });
    if (!secondSessionId || !code) return { skipped: 'code already taken' };
    claimed = true;
    const auth = await portal('/api/account/2auth', { type: 'MERCHANT', code, sessionId: secondSessionId });
    await saveCookies();
    await logEvent('code_sent', { result: String(auth?.resultCode ?? '') });
    if (String(auth?.resultCode ?? '') !== '2001' || !auth.sessionId) {
      return report({
        state: 'stopped',
        code: String(auth?.resultCode ?? ''),
        message: `Sahal did not accept the code${auth?.replyMessage ? `: ${auth.replyMessage}` : ''}. Sign in again for a new one.`,
      });
    }
    session = String(auth.sessionId);
    fresh = true;
    // The page shows the list that comes with this answer (transactionInfo).
    firstRows = rowArrays(auth.transactionInfo ?? [])[0] ?? [];
  }
  let tx = session ? await portal('/api/account/transactions', { sessionId: session }) : null;
  if (claimed && (!tx || ['4005', '7777'].includes(String(tx?.resultCode)))) {
    // Just signed in with the code, yet the list is refused: say exactly what Sahal answered.
    const rows = await withIds(firstRows);
    return report({
      state: 'stopped',
      code: String(tx?.resultCode ?? ''),
      message: `Signed in, but Sahal refused the transaction list (${tx?.resultCode ?? 'no answer'}: ${tx?.replyMessage ?? shape(tx)})`,
      rows,
    });
  }
  if (!tx || ['4005', '7777'].includes(String(tx.resultCode))) {
    if (session) await logEvent('session_lost', { by: 'list', code: String(tx?.resultCode ?? '') });
    // One sign-in at a time: each one makes Sahal text a new code.
    if (!(await rpc('merchant_feed_claim_sign_in', { p_provider: PROVIDER }))) return { skipped: 'sign-in running' };
    jar.clear();
    const login = await signIn();
    const code = String(login?.resultCode ?? '');
    await saveCookies();
    await logEvent('sign_in', { result: code });
    if (code === '1001' && login.sessionId) {
      // Sahal texted the access code: wait for a manager to enter it.
      await rpc('merchant_feed_wait_code', { p_provider: PROVIDER, p_second_session_id: String(login.sessionId) });
      return { waiting: 'code' };
    }
    if (code !== '2001' || !login.sessionId) {
      // A code, a password change or a refusal: stop until a manager retries.
      const why: Record<string, string> = {
        '1001': 'The portal asks for a second sign-in code',
        '6083': 'The portal asks for an SMS code',
        '6054': 'The portal asks for a new password',
      };
      return report({ state: 'stopped', code, message: why[code] ?? (login?.replyMessage || `Sign-in refused (${shape(login)})`) });
    }
    session = String(login.sessionId);
    fresh = true;
    tx = await portal('/api/account/transactions', { sessionId: session });
  }
  const code = String(tx?.resultCode ?? '');
  if (['4005', '7777'].includes(code)) {
    return report({ state: 'stopped', code, message: 'Signed in, but the session ended at once' });
  }
  const rows = rowArrays(tx)[0] ?? [];
  await saveCookies();
  const result = await report({
    state: 'ok',
    code,
    message: `${rows.length} rows; reply keys: ${shape(tx)}`,
    session,
    rows: await withIds([...firstRows, ...rows]),
  });
  if (fresh) await rpc('sahal_payout_retry_now', {}).catch(() => null);
  // A payout problem must not look like a feed problem (the feed read fine).
  const payouts = await sendPayouts(session!).catch((err) => ({ error: (err as Error).message }));
  return { feed: result, payouts };
}

const MAX_PAYOUTS_PER_RUN = 3;

const signIn = async () =>
  portal('/api/account/login', {
    type: 'MERCHANT',
    username: creds.username,
    password: creds.password,
    currency: await currency(),
  });

/** Reads Sahal's list with the session kept while a sign-in waits for a
 *  person; the rows are stored and matched, the feed's state is left as is. */
async function readWithKeptSession(feed: any) {
  jar.clear();
  for (const part of String(feed.readCookies ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) jar.set(part.slice(0, i).trim(), part.slice(i + 1).trim());
  }
  const tx = await portal('/api/account/transactions', { sessionId: feed.readSessionId });
  if (['4005', '7777'].includes(String(tx?.resultCode ?? ''))) {
    // That one has ended too: nothing to read with until the sign-in is done.
    await rpc('merchant_feed_keep_reading', { p_provider: PROVIDER, p_session_id: null, p_cookies: null });
    await logEvent('read_session_ended', { code: String(tx?.resultCode ?? '') });
    return { ended: String(tx?.resultCode ?? '') };
  }
  return rpc('merchant_feed_store_rows', { p_provider: PROVIDER, p_rows: await withIds(rowArrays(tx)[0] ?? []) });
}

/** Sahal refuses transfers for this session: sign in again now. The session
 *  is kept for reading meanwhile. Returns the new session, or null when
 *  Sahal wants its SMS code (or refused), which the alert chat is told. */
async function signInAgain(session: string): Promise<string | null> {
  await rpc('merchant_feed_keep_reading', { p_provider: PROVIDER, p_session_id: session, p_cookies: cookieHeader() });
  if (!(await rpc('merchant_feed_claim_sign_in', { p_provider: PROVIDER }))) return null;
  jar.clear();
  const login = await signIn();
  const code = String(login?.resultCode ?? '');
  await saveCookies();
  await logEvent('sign_in', { result: code, for: 'transfers' });
  if (code === '2001' && login.sessionId) {
    const fresh = String(login.sessionId);
    await report({ state: 'ok', code, message: 'Signed in again: Sahal had ended the session for transfers', session: fresh });
    await rpc('sahal_payout_retry_now', {});
    return fresh;
  }
  if (code === '1001' && login.sessionId) {
    await rpc('merchant_feed_wait_code', { p_provider: PROVIDER, p_second_session_id: String(login.sessionId) });
    return null;
  }
  await report({ state: 'stopped', code, message: `Sahal ended the session for transfers and refused a new sign-in: ${login?.replyMessage || shape(login)}` });
  return null;
}

/** The number looked up to check the session (no money moves). */
function probeMobile(): string | null {
  const set = Deno.env.get('GOLIS_MERCHANT_PROBE_MOBILE');
  if (set) return set;
  const login = String(creds.username ?? '');
  return /^(252)?\d{9}$/.test(login) ? login.replace(/^252/, '') : null;
}

/** Sahal no longer lets this session send money ("Session data is not found,
 *  please sign in again!"), although reading may still work. */
const sessionLost = (r: any) =>
  // ER0654 is the code whatever the words: "Session data is not found, please
  // sign in again!" one day, "Fadlan isku day markale" (try again) another.
  ['4005', '7777', 'ER0654'].includes(String(r?.resultCode ?? '').toUpperCase()) ||
  /sign in again|session/i.test(String(r?.replyMessage ?? ''));

/** POST /api/account/balance -> currentBalance; null when it cannot be read. */
async function balance(session: string): Promise<number | null> {
  try {
    const res = await portal('/api/account/balance', { sessionId: session });
    const value = Number(String(res?.currentBalance ?? '').replace(/,/g, ''));
    return String(res?.resultCode ?? '') === '2001' && Number.isFinite(value) ? value : null;
  } catch {
    return null;
  }
}

/** Sends the withdrawals the database hands out, one at a time. */
async function sendPayouts(session: string) {
  const pin = creds.pin;
  if (!pin) return { skipped: 'no merchant PIN' };
  const done: string[] = [];
  let signedInAgain = false;
  /** Lost for transfers: sign in again (once a run); true to go on with the new session. */
  const renew = async (by: string, code?: unknown) => {
    if (signedInAgain) return false;
    signedInAgain = true;
    await logEvent('session_lost', { by, code: code == null ? undefined : String(code) });
    const fresh = await signInAgain(session);
    if (!fresh) {
      done.push('Sahal session lost: signing in again');
      return false;
    }
    session = fresh;
    done.push('signed in again');
    return true;
  };
  for (let i = 0; i < MAX_PAYOUTS_PER_RUN; i++) {
    // Sahal's balance first (like the portal's dashboard): what it cannot pay waits.
    // No balance usually means the session has ended: take nothing now, so no
    // withdrawal is refused for it; the next run signs in again.
    const available = await balance(session);
    if (available === null) {
      if (i === 0) done.push('waiting: Sahal balance not read');
      break;
    }
    const next = await rpc('sahal_payout_next', { p_balance: available });
    if (!next?.attemptId) {
      // Nothing to send: check the session now rather than when a customer waits.
      // Setting 'sahal_renew_idle' off: not checked while idle, so a session
      // Sahal ended is renewed only when a withdrawal needs it (fewer SMS codes).
      const options = i === 0 && !signedInAgain ? await rpc('merchant_feed_options', { p_provider: PROVIDER }).catch(() => null) : null;
      const probe = i === 0 && !signedInAgain && options?.renewIdle !== false ? probeMobile() : null;
      if (probe) {
        const found = await portal('/api/account/find', { sessionId: session, type: 'internetwork', mobileNo: probe }).catch(() => null);
        if (sessionLost(found) && (await renew('probe', found?.resultCode))) continue;
      }
      break;
    }
    const say = (p_status: string, extra: Record<string, unknown> = {}) =>
      rpc('sahal_payout_report', { p_attempt_id: next.attemptId, p_status, ...extra });

    // 1. The receiver's name. Nothing is sent yet, so any trouble here is a refusal.
    let find: any;
    try {
      find = await portal('/api/account/find', { sessionId: session, type: 'internetwork', mobileNo: next.receiverMobile });
    } catch (err) {
      // Sahal not reached (timeout, network): nothing was sent, tried again in a minute.
      await say('failed', { p_result_code: 'NETWORK', p_reply: `Sahal not reached: ${(err as Error).message}` });
      done.push(`${next.orderCode}: Sahal not reached`);
      break;
    }
    const name = find?.ReceiverInfo?.NAME;
    if (String(find?.resultCode ?? '') !== '2001' || !name) {
      await say('failed', { p_result_code: String(find?.resultCode ?? ''), p_reply: find?.replyMessage ?? `No receiver (${shape(find)})` });
      done.push(`${next.orderCode}: failed`);
      if (sessionLost(find)) {
        if (await renew('lookup', find?.resultCode)) continue;
        break;
      }
      continue;
    }

    // 2. The transfer. From here on, only a clear answer counts.
    let sent: any;
    try {
      sent = await portal('/api/money/b2p', {
        sessionId: session,
        receiverMobile: next.receiverMobile,
        receiverName: name,
        pin,
        amount: next.amount,
        description: next.description,
        isInterNetwork: find.ReceiverInfo.ISINTERNETWORKRECEIVER,
      });
    } catch (err) {
      await say('ambiguous', { p_receiver_name: name, p_reply: `No answer to the transfer: ${(err as Error).message}` });
      done.push(`${next.orderCode}: unclear`);
      break;
    }
    const resultCode = String(sent?.resultCode ?? '');
    const transferId = sent?.transferInfo?.['Transfer-Id'];
    const reply = String(sent?.replyMessage ?? '').split(pin).join('••••');
    if (resultCode === '2001' && transferId) {
      await say('success', { p_receiver_name: name, p_transfer_id: String(transferId), p_result_code: resultCode, p_reply: reply });
      done.push(`${next.orderCode}: sent`);
    } else if (resultCode && resultCode !== '2001' && !['4005', '7777'].includes(resultCode) && reply) {
      // Sahal said no, with its reason: nothing was sent.
      await say('failed', { p_receiver_name: name, p_result_code: resultCode, p_reply: reply });
      done.push(`${next.orderCode}: refused`);
      if (sessionLost(sent)) {
        if (await renew('transfer', sent?.resultCode)) continue;
        break;
      }
    } else {
      await say('ambiguous', { p_receiver_name: name, p_result_code: resultCode, p_reply: reply || `Unclear answer (${shape(sent)})` });
      done.push(`${next.orderCode}: unclear`);
      break;
    }
  }
  return done;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  const secret = req.headers.get('x-worker-secret');
  if (!secret || (await rpc('platform_worker_check', { p_secret: secret }).catch(() => false)) !== true) {
    return new Response('Forbidden', { status: 403 });
  }
  try {
    return Response.json(await run());
  } catch (err) {
    // Could not reach or read the portal: try again next minute.
    const message = (err as Error).message;
    await report({ state: 'ready', code: 'error', message: `Portal not reached: ${message}` }).catch(() => {});
    return Response.json({ error: message }, { status: 502 });
  }
});
