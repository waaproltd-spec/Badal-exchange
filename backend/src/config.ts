import dotenv from 'dotenv';
dotenv.config();

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return v;
}

export const config = {
  port: parseInt(process.env.PORT || '4000', 10),
  nodeEnv: process.env.NODE_ENV || 'development',
  databaseUrl: required('DATABASE_URL'),
  jwtAccessSecret: required('JWT_ACCESS_SECRET'),
  jwtRefreshSecret: required('JWT_REFRESH_SECRET'),
  jwtAccessTtl: process.env.JWT_ACCESS_TTL || '15m',
  jwtRefreshTtl: process.env.JWT_REFRESH_TTL || '30d',
  credentialEncryptionKey: required('CREDENTIAL_ENCRYPTION_KEY'),
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
