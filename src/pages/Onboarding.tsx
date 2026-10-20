import { useState } from 'react';
import { useStore } from '../app/store';
import { createWorkspace, importWorkspaceJson, updateWorkspace } from '../database/repo';
import { enableVault } from '../security/vault';
import { openWithPassphrase } from '../security/crypto';
import { requestPersistentStorage } from '../database/db';

export function Onboarding() {
  const store = useStore();
  const [name, setName] = useState('My Family');
  const [pass, setPass] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const create = async () => {
    setErr(''); setBusy(true);
    try {
      let ws = await createWorkspace(name.trim() || 'My Family');
      let key: CryptoKey | undefined;
      if (pass) { const v = await enableVault(ws, pass); ws = v.ws; key = v.key; await updateWorkspace(ws); }
      await requestPersistentStorage();
      await store.openWorkspace(ws.id);
      if (key) store.setVaultKey(key);
      location.hash = '/io';
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };

  const restore = async (f: File) => {
    setErr(''); setBusy(true);
    try {
      let text = await f.text();
      const obj = JSON.parse(text);
      if (obj.format === 'omnitree-encrypted') text = await openWithPassphrase(prompt('Backup passphrase') ?? '', obj);
      const id = await importWorkspaceJson(text);
      await store.openWorkspace(id);
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };

  return (
    <div className="mx-auto grid min-h-full max-w-xl place-items-center p-4">
      <div className="panel w-full p-6">
        <div className="flex items-center gap-3"><img src={`${import.meta.env.BASE_URL}icon.svg`} className="h-12 w-12" alt="" /><div><h1 className="text-2xl font-semibold">Omni<span className="gold">Tree</span></h1><div className="muted text-sm">World Family Tree · local-first genealogy</div></div></div>
        {store.workspaces.length > 0 && (
          <div className="mt-6">
            <div className="label mb-2">Open a workspace</div>
            <div className="flex flex-col gap-2">{store.workspaces.map((w) => <button key={w.id} className="btn justify-between" onClick={() => store.openWorkspace(w.id)}>{w.name}<span className="muted text-xs">{w.vaultEnabled ? '🔒' : ''} {new Date(w.createdAt).toLocaleDateString()}</span></button>)}</div>
          </div>
        )}
        <div className="mt-6 space-y-3">
          <div className="label">Create a new family workspace</div>
          <label className="block text-sm">Name<input className="input mt-1" value={name} onChange={(e) => setName(e.target.value)} data-testid="ws-name" /></label>
          <label className="block text-sm">Vault passphrase (optional, encrypts DNA files)<input type="password" className="input mt-1" value={pass} onChange={(e) => setPass(e.target.value)} placeholder="At least 8 characters" autoComplete="new-password" /></label>
          <p className="text-xs muted">Your data stays in this browser. Nothing is uploaded. If you forget the passphrase, encrypted DNA cannot be recovered.</p>
          <button className="btn btn-primary w-full justify-center" disabled={busy} onClick={create} data-testid="create-ws">Create workspace</button>
          <label className="btn w-full justify-center cursor-pointer">Restore from backup…<input type="file" accept=".json,.omnitree" className="hidden" onChange={(e) => e.target.files?.[0] && restore(e.target.files[0])} /></label>
          {err && <div role="alert" className="text-sm text-red-500">{err}</div>}
        </div>
      </div>
    </div>
  );
}
