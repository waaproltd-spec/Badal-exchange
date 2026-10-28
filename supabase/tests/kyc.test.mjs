// KYC (migrations/*_kyc.sql): the server's own checks, Admin Review when no
// identity service is configured (never approved on the form or the images
// alone), automatic approval only when the service verifies it AND every
// check passes, admin approve / reject / resubmission with reasons, one open
// application, and who may see the documents. Run with the other suites.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import { randomBytes } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const service = SERVICE_KEY ? createClient(URL, SERVICE_KEY, opts) : null;

async function login(phone) {
  const c = createClient(URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email: `${phone.replace(/\D/g, '')}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}
async function rpc(c, fn, args = {}) {
  const { data, error } = await c.rpc(fn, args);
  if (error) {
    const e = new Error(`${fn}: ${error.message}`);
    e.code = error.hint ?? error.code;
    throw e;
  }
  return data;
}
async function rejects(promise, code) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    return true;
  });
}

// A real PNG of noise (noise so it does not compress below "readable").
const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(width, height) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 0; // 8-bit grey
  const rows = [];
  for (let y = 0; y < height; y++) rows.push(Buffer.concat([Buffer.from([0]), randomBytes(width)]));
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))]).toString('base64');
}
const goodDoc = png(800, 600);
const goodSelfie = png(500, 500);
const tinyImage = png(120, 90);

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let manager;
async function customer(name = 'Yasin Mohamed') {
  const phone = `25261${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, $2, private.hash_password($3)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 0 FROM u RETURNING customer_id`, [phone, name, PASSWORD]);
  return { c: await login(phone), id: u.customer_id, phone };
}
const passport = (overrides = {}) => ({
  p_document_type: 'passport', p_full_name: 'Yasin Mohamed Adan', p_document_number: 'P1234567', p_country: 'SO',
  p_date_of_birth: '1995-03-01', p_expiry_date: '2030-01-01', p_front: goodDoc, p_back: null, p_selfie: goodSelfie, ...overrides,
});
const failed = (status) => status.checks?.filter((c) => !c.ok).map((c) => c.key);
const detail = (id) => rpc(manager, 'manage_kyc_application', { p_id: id });

let providerSetting;
before(async () => {
  manager = await login('252610000002');
  providerSetting = (await db.query(`SELECT value FROM app_settings WHERE key = 'kyc:provider'`)).rows[0]?.value;
});
after(async () => {
  await db.query(`UPDATE app_settings SET value = $1 WHERE key = 'kyc:provider'`, [providerSetting ?? 'none']);
  await db.end();
});

test('not submitted at first', async () => {
  const cu = await customer();
  const s = await rpc(cu.c, 'customer_kyc_status');
  assert.deepEqual([s.status, s.canSubmit], ['not_submitted', true]);
});

test('valid passport, no identity service configured: Admin Review, never approved on the form and images alone', async () => {
  const cu = await customer();
  const s = await rpc(cu.c, 'customer_submit_kyc', passport());
  assert.equal(s.status, 'pending_review');
  const d = await detail(s.id);
  assert.deepEqual(failed(d), [], 'every check passed');
  assert.match(d.reviewReason, /No identity-verification service/);
  assert.equal(d.documents.front.mime, 'image/png');
  // One line of base64 (no line breaks): the Agent App's decoder refuses them.
  assert.ok(d.documents.front.data.length > 76 && !/\s/.test(d.documents.front.data), 'no line breaks');
  assert.equal(Buffer.from(d.documents.front.data, 'base64').subarray(1, 4).toString(), 'PNG');
  assert.deepEqual([d.documents.front.width, d.documents.front.height], [800, 600]);
  assert.equal(d.documents.back, undefined, 'a passport has no back');
  assert.ok(d.autoCheckedAt);
  const { rows } = await db.query(`SELECT status FROM withdrawal_approvals WHERE customer_id = $1`, [cu.id]);
  assert.ok(rows.length === 0 || rows[0].status !== 'approved', 'withdrawals not approved by a submission');
});

test('invalid details, unreadable images and a name that does not match: Admin Review, each reason recorded', async () => {
  const cu = await customer('Ahmed Ali');
  const s = await rpc(cu.c, 'customer_submit_kyc', passport({
    p_document_number: 'P1', p_country: 'XX', p_date_of_birth: '2015-01-01', p_expiry_date: '2020-01-01',
    p_front: tinyImage, p_selfie: Buffer.from('not an image at all').toString('base64'),
  }));
  assert.equal(s.status, 'pending_review');
  const d = await detail(s.id);
  assert.deepEqual(failed(d).sort(), ['country', 'date_of_birth', 'document_number', 'expiry_date', 'image_front', 'image_selfie',
    'name_matches_account'].sort());
  assert.match(d.reviewReason, /Some checks did not pass/);
  assert.match(d.checks.find((c) => c.key === 'image_front').detail, /120x90/);
  assert.match(d.checks.find((c) => c.key === 'image_selfie').detail, /Not a JPEG or PNG/);
});

test('national ID needs the back too; a missing image is a failed check', async () => {
  const cu = await customer();
  const s = await rpc(cu.c, 'customer_submit_kyc', passport({ p_document_type: 'national_id', p_document_number: 'NID789456' }));
  assert.deepEqual(failed(await detail(s.id)), ['image_back']);
  await rejects(rpc(cu.c, 'customer_submit_kyc', passport({ p_document_type: 'driving_licence' })), 'VALIDATION_ERROR');
});

test('one application at a time: a second is refused while one is open', async () => {
  const cu = await customer();
  await rpc(cu.c, 'customer_submit_kyc', passport());
  await rejects(rpc(cu.c, 'customer_submit_kyc', passport()), 'KYC_ALREADY_SUBMITTED');
  const both = await Promise.allSettled([1, 2, 3].map(() => rpc(cu.c, 'customer_submit_kyc', passport())));
  assert.ok(both.every((r) => r.status === 'rejected'));
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM kyc_applications WHERE customer_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 1);
});

test('admin: approve (with a reason, who and when) also approves withdrawals; reject and resubmission need reasons', async () => {
  const a = await customer();
  const s = await rpc(a.c, 'customer_submit_kyc', passport());
  await rejects(rpc(manager, 'manage_decide_kyc', { p_id: s.id, p_decision: 'approve', p_reason: '' }), 'VALIDATION_ERROR');
  const r = await rpc(manager, 'manage_decide_kyc', { p_id: s.id, p_decision: 'approve', p_reason: 'Passport checked against selfie' });
  assert.equal(r.status, 'approved');
  const st = await rpc(a.c, 'customer_kyc_status');
  assert.deepEqual([st.status, st.canSubmit], ['approved', false]);
  const d = await detail(s.id);
  assert.ok(d.decidedBy && d.decidedAt);
  assert.equal(d.decisionReason, 'Passport checked against selfie');
  const { rows: [w] } = await db.query(`SELECT status FROM withdrawal_approvals WHERE customer_id = $1`, [a.id]);
  assert.equal(w.status, 'approved', 'KYC approved -> may withdraw');
  await rejects(rpc(manager, 'manage_decide_kyc', { p_id: s.id, p_decision: 'reject', p_reason: 'late' }), 'KYC_ALREADY_DECIDED');
  await rejects(rpc(a.c, 'customer_submit_kyc', passport()), 'KYC_ALREADY_SUBMITTED');

  const b = await customer();
  const sb = await rpc(b.c, 'customer_submit_kyc', passport());
  await rpc(manager, 'manage_decide_kyc', { p_id: sb.id, p_decision: 'resubmit', p_reason: 'The passport photo is blurred' });
  let sbs = await rpc(b.c, 'customer_kyc_status');
  assert.deepEqual([sbs.status, sbs.reason, sbs.canSubmit], ['resubmission_required', 'The passport photo is blurred', true]);
  const again = await rpc(b.c, 'customer_submit_kyc', passport());
  assert.equal(again.status, 'pending_review', 'resubmitted');
  assert.equal((await detail(again.id)).history.length, 1, 'the earlier one in the history');
  await rpc(manager, 'manage_decide_kyc', { p_id: again.id, p_decision: 'reject', p_reason: 'Document does not match the person' });
  sbs = await rpc(b.c, 'customer_kyc_status');
  assert.deepEqual([sbs.status, sbs.reason], ['rejected', 'Document does not match the person']);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE entity_id IN ($1, $2) AND action LIKE 'kyc.%'`, [sb.id, again.id]);
  assert.ok(rows[0].n >= 4);
});

test('with an identity service: approved automatically only when it verifies AND every check passed', async (t) => {
  if (!service) return t.skip('set SUPABASE_SERVICE_ROLE_KEY');
  await db.query(`UPDATE app_settings SET value = 'testprovider' WHERE key = 'kyc:provider'`);
  try {
    const a = await customer();
    const sa = await rpc(a.c, 'customer_submit_kyc', passport());
    assert.equal(sa.status, 'pending_auto');
    assert.equal((await rpc(service, 'kyc_record_provider_result', { p_application_id: sa.id, p_verified: true, p_result: { score: 0.98 } })).status, 'approved');
    const d = await detail(sa.id);
    assert.match(d.decisionReason, /Verified automatically by testprovider/);
    assert.equal(d.decidedBy, null);
    assert.equal(d.providerResult.score, 0.98);

    const b = await customer();
    const sb = await rpc(b.c, 'customer_submit_kyc', passport());
    assert.equal((await rpc(service, 'kyc_record_provider_result', { p_application_id: sb.id, p_verified: false })).status, 'pending_review',
      'the service could not verify: an admin');

    const c = await customer('Somebody Else');
    const sc = await rpc(c.c, 'customer_submit_kyc', passport());
    assert.equal((await rpc(service, 'kyc_record_provider_result', { p_application_id: sc.id, p_verified: true })).status, 'pending_review',
      'verified, but the name does not match the account: an admin');
    assert.match((await detail(sc.id)).reviewReason, /some checks did not pass/);
  } finally {
    await db.query(`UPDATE app_settings SET value = 'none' WHERE key = 'kyc:provider'`);
  }
});

test('nobody else changes a status or sees the documents', async () => {
  const cu = await customer();
  const s = await rpc(cu.c, 'customer_submit_kyc', passport());
  await rejects(rpc(cu.c, 'manage_decide_kyc', { p_id: s.id, p_decision: 'approve', p_reason: 'myself' }), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'manage_kyc_application', { p_id: s.id }), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'manage_kyc_applications'), 'FORBIDDEN');
  assert.ok((await cu.c.rpc('kyc_record_provider_result', { p_application_id: s.id, p_verified: true })).error, 'service only');
  for (const table of ['kyc_applications', 'kyc_documents']) {
    const { error } = await cu.c.from(table).select('*');
    assert.ok(error, `${table} not readable`);
  }
  const list = await rpc(manager, 'manage_kyc_applications', { p_status: 'pending_review', p_query: cu.phone.slice(-7) });
  assert.equal(list.applications.length, 1);
  assert.equal(list.applications[0].documentNumber, 'P1234567');
});
