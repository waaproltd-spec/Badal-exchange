// Home Ad picture (migrations/*_home_ad_image.sql): chosen from the gallery,
// kept with the ad, shown to customers, replaceable and removable, validated,
// and a rejected upload leaves the ad and its picture untouched. Run with the
// other suites: npm test.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const PASSWORD = 'ChangeMe123!';
const opts = { auth: { persistSession: false, autoRefreshToken: false } };

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

// A 1 x 1 PNG and the first bytes of a JPEG and a WebP.
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==', 'base64');
const JPEG = Buffer.concat([Buffer.from('ffd8ffe000104a464946', 'hex'), Buffer.alloc(2000, 7)]);
const WEBP = Buffer.concat([Buffer.from('52494646', 'hex'), Buffer.alloc(4), Buffer.from('57454250', 'hex'), Buffer.alloc(100)]);
const b64 = (b) => b.toString('base64');

let manager;
let customer;
const ids = [];
const save = async (args) => {
  const ad = await rpc(manager, 'manage_save_home_ad', args);
  if (!ids.includes(ad.id)) ids.push(ad.id);
  return ad;
};
const mine = async (id) => (await rpc(customer, 'customer_home_ads')).find((a) => a.id === id);

before(async () => {
  manager = await login('252610000002');
  customer = await login('252610000003');
});

test('an ad without a picture works as before (the image is optional)', async () => {
  const ad = await save({ p_title: 'No picture', p_image_url: 'https://example.com/a.png' });
  assert.equal(ad.image, null);
  assert.equal(ad.imageUrl, 'https://example.com/a.png');
  const again = await save({ p_id: ad.id, p_title: 'No picture', p_image_url: 'https://example.com/a.png' });
  assert.equal(again.imageUrl, 'https://example.com/a.png', 'an old link is kept when no picture is chosen');
});

test('a picture is saved with the ad, shown to customers, and survives later edits', async () => {
  const ad = await save({ p_title: 'With picture', p_image: b64(PNG) });
  assert.equal(ad.image, b64(PNG));
  assert.equal(ad.imageType, 'image/png');
  assert.equal((await mine(ad.id)).image, b64(PNG), 'customers get the picture');

  // Editing the text without choosing a new picture keeps the one saved.
  const edited = await save({ p_id: ad.id, p_title: 'With picture, edited', p_enabled: true });
  assert.equal(edited.title, 'With picture, edited');
  assert.equal(edited.image, b64(PNG));
  assert.equal((await mine(ad.id)).image, b64(PNG));
});

test('a new picture replaces the old one (and an old link); JPEG and WebP are accepted', async () => {
  const ad = await save({ p_title: 'Replace me', p_image_url: 'https://example.com/old.png', p_image: b64(PNG) });
  assert.equal(ad.imageUrl, null, 'the picture takes the place of the old link');
  const jpeg = await save({ p_id: ad.id, p_title: 'Replace me', p_image: b64(JPEG) });
  assert.equal(jpeg.image, b64(JPEG));
  assert.equal(jpeg.imageType, 'image/jpeg');
  const webp = await save({ p_id: ad.id, p_title: 'Replace me', p_image: b64(WEBP) });
  assert.equal(webp.imageType, 'image/webp');
  assert.equal((await mine(ad.id)).image, b64(WEBP));
});

test('a rejected picture changes nothing: the ad and its previous picture stay', async () => {
  const ad = await save({ p_title: 'Keep me', p_image: b64(PNG) });
  const bad = [
    'not base64!!',
    b64(Buffer.from('this is text, not a picture')),
    b64(Buffer.concat([Buffer.from('ffd8ff', 'hex'), Buffer.alloc(610000)])),
    b64(Buffer.from('474946383961', 'hex')),
  ];
  for (const p_image of bad) {
    await rejects(rpc(manager, 'manage_save_home_ad', { p_id: ad.id, p_title: 'Changed?', p_image }), 'VALIDATION_ERROR');
  }
  const now = await mine(ad.id);
  assert.equal(now.title, 'Keep me');
  assert.equal(now.image, b64(PNG));
});

test('the picture can be removed; only managers can save', async () => {
  const ad = await save({ p_title: 'Remove it', p_image: b64(PNG), p_image_url: 'https://example.com/x.png' });
  const removed = await save({ p_id: ad.id, p_title: 'Remove it', p_remove_image: true, p_image_url: 'https://example.com/x.png' });
  assert.equal(removed.image, null);
  assert.equal(removed.imageUrl, null);
  assert.equal((await mine(ad.id)).image, null);
  await rejects(rpc(customer, 'manage_save_home_ad', { p_title: 'Nope', p_image: b64(PNG) }), 'FORBIDDEN');
});

test('a manager sees the ad with its picture, and deleting it removes it for customers', async () => {
  const ad = await save({ p_title: 'Deleted', p_image: b64(PNG) });
  const listed = (await rpc(manager, 'manage_home_ads')).find((a) => a.id === ad.id);
  assert.equal(listed.image, b64(PNG));
  await rpc(manager, 'manage_delete_home_ad', { p_id: ad.id });
  assert.ok(!(await rpc(customer, 'customer_home_ads')).some((a) => a.id === ad.id));
  ids.splice(ids.indexOf(ad.id), 1);
});

test('tidy up the ads made here', async () => {
  for (const id of ids) await rpc(manager, 'manage_delete_home_ad', { p_id: id });
});
