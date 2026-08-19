import { pool } from './pool';
import { hashPassword } from '../lib/crypto';

async function upsertUser(role: string, phone: string, name: string, password: string) {
  const passwordHash = await hashPassword(password);
  const { rows } = await pool.query(
    `INSERT INTO users (role, phone, name, password_hash) VALUES ($1,$2,$3,$4)
     ON CONFLICT (phone) DO UPDATE SET name = EXCLUDED.name
     RETURNING id`,
    [role, phone, name, passwordHash]
  );
  return rows[0].id as string;
}

async function main() {
  console.log('Seeding Badal Exchange demo data...');

  const adminId = await upsertUser('admin', '252610000001', 'Super Admin', 'ChangeMe123!');
  await pool.query(
    `INSERT INTO admin_profiles (user_id, admin_role) VALUES ($1, 'super_admin') ON CONFLICT (user_id) DO NOTHING`,
    [adminId]
  );

  const agentId = await upsertUser('agent', '252610000002', 'Demo Agent', 'ChangeMe123!');
  await pool.query(
    `INSERT INTO agent_profiles (user_id, responsibilities) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING`,
    [agentId, ['evc_deposit', 'evc_withdraw']]
  );

  const customerId = await upsertUser('customer', '252610000003', 'Demo Customer', 'ChangeMe123!');
  await pool.query(`INSERT INTO wallets (customer_id) VALUES ($1) ON CONFLICT (customer_id) DO NOTHING`, [customerId]);

  // Exchange rates: 1:1 by default (admin can change any time; each order snapshots the rate in force).
  const rates: Array<[string, string, number]> = [
    ['evc_plus', 'deposit', 1.0],
    ['evc_plus', 'withdraw', 1.0],
    ['winwin', 'deposit', 1.0],
    ['winwin', 'withdraw', 1.0],
  ];
  for (const [method, direction, rate] of rates) {
    const exists = await pool.query(
      `SELECT 1 FROM exchange_rates WHERE method=$1 AND direction=$2 AND active=true`,
      [method, direction]
    );
    if (!exists.rows[0]) {
      await pool.query(
        `INSERT INTO exchange_rates (method, direction, rate, created_by) VALUES ($1,$2,$3,$4)`,
        [method, direction, rate, adminId]
      );
    }
  }

  // Fees: flat $0.20 on deposits, 1% on withdrawals (values are illustrative demo defaults).
  const fees: Array<[string, string, 'flat' | 'percent', number]> = [
    ['evc_plus', 'deposit', 'flat', 20],
    ['evc_plus', 'withdraw', 'percent', 1],
    ['winwin', 'deposit', 'flat', 20],
    ['winwin', 'withdraw', 'percent', 1],
  ];
  for (const [method, direction, feeType, value] of fees) {
    const exists = await pool.query(`SELECT 1 FROM fees WHERE method=$1 AND direction=$2 AND active=true`, [
      method,
      direction,
    ]);
    if (!exists.rows[0]) {
      await pool.query(`INSERT INTO fees (method, direction, fee_type, value, created_by) VALUES ($1,$2,$3,$4,$5)`, [
        method,
        direction,
        feeType,
        value,
        adminId,
      ]);
    }
  }

  // Withdrawal limits: $1 min, $500 max per request (demo defaults).
  for (const method of ['evc_plus', 'winwin']) {
    await pool.query(
      `INSERT INTO withdrawal_limits (method, min_cents, max_cents) VALUES ($1, 100, 50000)
       ON CONFLICT (method) DO NOTHING`,
      [method]
    );
  }

  // Payment integrations: rows created inactive, no credentials, ready for
  // an admin to configure via Admin -> Payment Integrations.
  for (const provider of ['evc_plus', 'mobcash_winwin']) {
    await pool.query(
      `INSERT INTO payment_integrations (provider, status, config_json) VALUES ($1, 'inactive', '{}')
       ON CONFLICT (provider) DO NOTHING`,
      [provider]
    );
  }

  console.log('Seed complete.');
  console.log('  Admin login:    phone=252610000001 password=ChangeMe123!');
  console.log('  Agent login:    phone=252610000002 password=ChangeMe123!');
  console.log('  Customer login: phone=252610000003 password=ChangeMe123!');
  await pool.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
