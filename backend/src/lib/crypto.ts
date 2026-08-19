import bcrypt from 'bcryptjs';
import crypto from 'crypto';
import { config } from '../config';

// ---------------------------------------------------------------------------
// Password hashing (user login credentials)
// ---------------------------------------------------------------------------
export async function hashPassword(plain: string): Promise<string> {
  return bcrypt.hash(plain, 12);
}

export async function verifyPassword(plain: string, hash: string): Promise<boolean> {
  return bcrypt.compare(plain, hash);
}

// ---------------------------------------------------------------------------
// Symmetric encryption for sensitive third-party credentials (MobCash /
// EVC Plus manager account username & password). AES-256-GCM with a
// server-only master key from CREDENTIAL_ENCRYPTION_KEY. Ciphertext, IV and
// auth tag are stored separately; nothing sensitive is ever logged.
// ---------------------------------------------------------------------------
const ALGO = 'aes-256-gcm';

function masterKey(): Buffer {
  const key = Buffer.from(config.credentialEncryptionKey, 'hex');
  if (key.length !== 32) {
    throw new Error('CREDENTIAL_ENCRYPTION_KEY must be 32 bytes (64 hex chars)');
  }
  return key;
}

export interface EncryptedField {
  ciphertext: Buffer;
  iv: Buffer;
  authTag: Buffer;
}

export function encryptSecret(plaintext: string): EncryptedField {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(ALGO, masterKey(), iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  return { ciphertext, iv, authTag: cipher.getAuthTag() };
}

export function decryptSecret(field: EncryptedField): string {
  const decipher = crypto.createDecipheriv(ALGO, masterKey(), field.iv);
  decipher.setAuthTag(field.authTag);
  const plaintext = Buffer.concat([decipher.update(field.ciphertext), decipher.final()]);
  return plaintext.toString('utf8');
}

// ---------------------------------------------------------------------------
// Human-facing codes
// ---------------------------------------------------------------------------
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I ambiguity

function randomCode(length: number): string {
  let out = '';
  const bytes = crypto.randomBytes(length);
  for (let i = 0; i < length; i++) {
    out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return out;
}

/** Short unique code shown to the customer for WinWin deposit matching, e.g. A5BC */
export function generateDepositCode(): string {
  return randomCode(4);
}

/** Human-facing order id, e.g. EX93K2F1 */
export function generateOrderCode(): string {
  return `EX${randomCode(6)}`;
}

export function newIdempotencyRequestHash(payload: unknown): string {
  return crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex');
}
