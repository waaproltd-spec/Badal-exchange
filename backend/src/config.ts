import dotenv from 'dotenv';
dotenv.config();

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return v;
}

// The MobCash automation worker (src/worker.ts, BAARI_PROCESS=worker) serves
// no API, so it doesn't need the API's token secrets.
const isWorker = process.env.BAARI_PROCESS === 'worker';
function requiredForApi(name: string): string {
  return isWorker ? process.env[name] || 'unused-by-worker' : required(name);
}

export const config = {
  port: parseInt(process.env.PORT || '4000', 10),
  nodeEnv: process.env.NODE_ENV || 'development',
  databaseUrl: required('DATABASE_URL'),
  // 'auto' turns SSL on for hosted Postgres (e.g. Supabase) and off for
  // localhost. 'require' encrypts without verifying the server certificate;
  // 'verify' also verifies it (set DATABASE_SSL_CA to the provider's CA
  // certificate, e.g. Supabase's prod-ca-2021.crt). 'disable' turns SSL off.
  databaseSsl: (process.env.DATABASE_SSL || 'auto') as 'auto' | 'disable' | 'require' | 'verify',
  databaseSslCa: process.env.DATABASE_SSL_CA,
  // Supabase's poolers cap client connections per project, so keep this
  // within the plan's limit.
  databasePoolMax: parseInt(process.env.DATABASE_POOL_MAX || '20', 10),
  jwtAccessSecret: requiredForApi('JWT_ACCESS_SECRET'),
  jwtRefreshSecret: requiredForApi('JWT_REFRESH_SECRET'),
  jwtAccessTtl: process.env.JWT_ACCESS_TTL || '15m',
  jwtRefreshTtl: process.env.JWT_REFRESH_TTL || '30d',
  credentialEncryptionKey: requiredForApi('CREDENTIAL_ENCRYPTION_KEY'),
  adminDashboardOrigin: process.env.ADMIN_DASHBOARD_ORIGIN || 'http://localhost:5173',
  // CashdeskBot: optional at startup -- these come from the API manager and
  // may not exist yet. Checked lazily by cashdeskBotService when actually
  // called, not at boot, so the backend doesn't crash without them.
  cashdeskBot: {
    baseUrl: process.env.CASHDESKBOT_BASE_URL || 'https://partners.servcul.com/CashdeskBotAPI',
    login: process.env.CASHDESKBOT_LOGIN,
    cashierpass: process.env.CASHDESKBOT_CASHIERPASS,
    hash: process.env.CASHDESKBOT_HASH,
    cashdeskid: process.env.CASHDESKBOT_CASHDESKID,
  },
};
