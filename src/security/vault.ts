import type { TreeWorkspace } from '../database/types';
import { decryptText, deriveKey, encryptText, fromB64, randomBytes, toB64 } from './crypto';

const CHECK = 'omnitree-vault-ok';

/** Enable passphrase protection on a workspace. Returns the updated workspace and the unlocked key. */
export async function enableVault(ws: TreeWorkspace, passphrase: string): Promise<{ ws: TreeWorkspace; key: CryptoKey }> {
  if (passphrase.length < 8) throw new Error('Use a passphrase of at least 8 characters');
  const salt = randomBytes(16);
  const key = await deriveKey(passphrase, salt);
  const check = await encryptText(key, CHECK);
  return { key, ws: { ...ws, vaultEnabled: true, vaultSalt: toB64(salt), vaultCheck: toB64(check.data), vaultCheckIv: check.iv } };
}

export async function unlockVault(ws: TreeWorkspace, passphrase: string): Promise<CryptoKey> {
  if (!ws.vaultEnabled || !ws.vaultSalt || !ws.vaultCheck || !ws.vaultCheckIv) throw new Error('Vault not enabled');
  const key = await deriveKey(passphrase, fromB64(ws.vaultSalt));
  try {
    const ct = fromB64(ws.vaultCheck);
    if ((await decryptText(key, ws.vaultCheckIv, ct.buffer as ArrayBuffer)) === CHECK) return key;
  } catch { /* fall through */ }
  throw new Error('Incorrect passphrase');
}
