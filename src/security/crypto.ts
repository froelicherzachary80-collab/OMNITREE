/**
 * Client-side encryption using the browser's audited WebCrypto implementation:
 * PBKDF2-SHA256 (310,000 iterations) key derivation + AES-256-GCM.
 */
const ITERATIONS = 310_000;
const enc = new TextEncoder();
const dec = new TextDecoder();

export const toB64 = (b: ArrayBuffer | Uint8Array) => {
  const u = b instanceof Uint8Array ? b : new Uint8Array(b);
  let s = '';
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
  return btoa(s);
};
export const fromB64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

export function randomBytes(n: number) { return crypto.getRandomValues(new Uint8Array(n)); }

export async function deriveKey(passphrase: string, salt: Uint8Array, iterations = ITERATIONS): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey('raw', enc.encode(passphrase), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'PBKDF2', salt: salt as BufferSource, iterations, hash: 'SHA-256' }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

export async function encryptBytes(key: CryptoKey, data: Uint8Array): Promise<{ iv: string; data: ArrayBuffer }> {
  const iv = randomBytes(12);
  return { iv: toB64(iv), data: await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, data as BufferSource) };
}

export async function decryptBytes(key: CryptoKey, iv: string, data: ArrayBuffer): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: fromB64(iv) as BufferSource }, key, data));
}

export const encryptText = (key: CryptoKey, s: string) => encryptBytes(key, enc.encode(s));
export const decryptText = async (key: CryptoKey, iv: string, data: ArrayBuffer) => dec.decode(await decryptBytes(key, iv, data));

export interface EncryptedEnvelope { format: 'omnitree-encrypted'; version: 1; kdf: 'PBKDF2-SHA256'; iterations: number; salt: string; iv: string; ciphertext: string }

/** Self-contained passphrase-encrypted envelope (used for backups). */
export async function sealWithPassphrase(passphrase: string, plaintext: string, iterations = ITERATIONS): Promise<EncryptedEnvelope> {
  const salt = randomBytes(16);
  const key = await deriveKey(passphrase, salt, iterations);
  const { iv, data } = await encryptText(key, plaintext);
  return { format: 'omnitree-encrypted', version: 1, kdf: 'PBKDF2-SHA256', iterations, salt: toB64(salt), iv, ciphertext: toB64(data) };
}

export async function openWithPassphrase(passphrase: string, env: EncryptedEnvelope): Promise<string> {
  const key = await deriveKey(passphrase, fromB64(env.salt), env.iterations);
  try {
    const ct = fromB64(env.ciphertext);
    return await decryptText(key, env.iv, ct.buffer.slice(ct.byteOffset, ct.byteOffset + ct.byteLength) as ArrayBuffer);
  } catch {
    throw new Error('Wrong passphrase or corrupted backup');
  }
}
