// Writes tests/.functions.env for `supabase functions serve --env-file`:
// the stand-in CashdeskBot settings (player_lookup.env) plus a throwaway
// Firebase service account (a fresh RSA key, never a real one) whose token
// and FCM endpoints point at the stand-in in push_notifications.test.mjs.
//
//   node tests/make-functions-env.mjs && supabase functions serve --env-file tests/.functions.env
import { generateKeyPairSync } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const here = (f) => new globalThis.URL(f, import.meta.url);
// The Docker network's gateway: this machine, seen from the functions
// (FUNCTIONS_GATEWAY in CI, where it may differ).
const gateway = process.env.FUNCTIONS_GATEWAY || '172.18.0.1';
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const account = {
  type: 'service_account',
  project_id: 'baari-test',
  client_email: 'push@baari-test.iam.gserviceaccount.com',
  private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  token_uri: `http://${gateway}:4996/token`,
};
writeFileSync(here('.functions.env'), [
  readFileSync(here('player_lookup.env'), 'utf8').trim().replaceAll('172.18.0.1', gateway),
  `FIREBASE_SERVICE_ACCOUNT=${Buffer.from(JSON.stringify(account)).toString('base64')}`,
  `FCM_API_URL=http://${gateway}:4996`,
  '',
].join('\n'));
console.log('wrote tests/.functions.env');
