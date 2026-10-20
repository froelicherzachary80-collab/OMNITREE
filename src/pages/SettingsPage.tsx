import { useEffect, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonLink } from '../components/common';
import { enableVault, unlockVault } from '../security/vault';
import { deleteWorkspace, updateWorkspace } from '../database/repo';
import { getDb, requestPersistentStorage } from '../database/db';
import type { AuditEvent } from '../database/types';

export default function SettingsPage() {
  const store = useStore();
  const ws = store.workspace!;
  const [pass, setPass] = useState('');
  const [msg, setMsg] = useState('');
  const [persist, setPersist] = useState<string>('unknown');
  const [usage, setUsage] = useState('');
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  useEffect(() => {
    navigator.storage?.persisted?.().then((p) => setPersist(p ? 'granted' : 'not granted'));
    navigator.storage?.estimate?.().then((e) => setUsage(`${((e.usage ?? 0) / 1e6).toFixed(1)} MB used of ~${((e.quota ?? 0) / 1e6).toFixed(0)} MB`));
    getDb().audit.where('workspaceId').equals(ws.id).reverse().sortBy('at').then((a) => setAudit(a.slice(0, 50)));
  }, [ws.id, store.version]);
  const run = async (f: () => Promise<void>) => { setMsg(''); try { await f(); } catch (e) { setMsg((e as Error).message); } };
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card title="Workspace">
        <p className="text-sm">Name: <b>{ws.name}</b></p>
        <p className="text-sm">Home person: {ws.rootPersonId ? <PersonLink id={ws.rootPersonId} /> : 'not set (use “Set as home person” on a profile)'}</p>
        <div className="mt-3 flex flex-wrap gap-2">
          <button className="btn" onClick={() => store.openWorkspace(undefined)}>Switch workspace</button>
          <button className="btn" onClick={() => store.setTheme(store.theme === 'dark' ? 'light' : 'dark')}>Theme: {store.theme}</button>
          <button className="btn btn-danger" onClick={() => run(async () => { if (prompt(`Type the workspace name "${ws.name}" to permanently delete all its data, including DNA`) !== ws.name) return; await deleteWorkspace(ws.id); await store.openWorkspace(undefined); })}>Delete workspace</button>
        </div>
      </Card>
      <Card title="Data vault">
        <p className="text-sm">Status: <b>{ws.vaultEnabled ? (store.vaultKey ? 'enabled · unlocked' : 'enabled · locked') : 'not enabled'}</b>. DNA kits saved while unlocked are encrypted with AES-256-GCM (key from PBKDF2-SHA256).</p>
        <input type="password" className="input mt-2" placeholder="Passphrase" value={pass} onChange={(e) => setPass(e.target.value)} aria-label="Vault passphrase" />
        <div className="mt-2 flex flex-wrap gap-2">
          {!ws.vaultEnabled && <button className="btn btn-primary" onClick={() => run(async () => { const v = await enableVault(ws, pass); await updateWorkspace(v.ws); await store.reload(); store.setVaultKey(v.key); setPass(''); setMsg('Vault enabled. Kits uploaded earlier stay unencrypted; re-upload them to encrypt.'); })}>Enable vault</button>}
          {ws.vaultEnabled && !store.vaultKey && <button className="btn btn-primary" onClick={() => run(async () => { store.setVaultKey(await unlockVault(ws, pass)); setPass(''); })}>Unlock</button>}
          {store.vaultKey && <button className="btn" onClick={() => store.setVaultKey(undefined)}>Lock</button>}
        </div>
        {msg && <p role="alert" className="mt-2 text-sm text-amber-500">{msg}</p>}
      </Card>
      <Card title="Storage & privacy">
        <p className="text-sm">Persistent storage: <b>{persist}</b> · {usage}</p>
        <button className="btn mt-2" onClick={() => run(async () => { const r = await requestPersistentStorage(); setPersist(r === true ? 'granted' : String(r === 'unsupported' ? 'unsupported' : 'not granted')); })}>Request persistent storage</button>
        <ul className="mt-3 list-disc pl-5 text-sm muted">
          <li>Everything is stored locally in IndexedDB. Cloud sync is off and not implemented.</li>
          <li>No DNA or living-person data is sent to any AI service; OmniAI runs locally.</li>
          <li>The audit log records metadata only, never genotypes.</li>
          <li>Consent to process a relative’s DNA is not consent to publish it.</li>
        </ul>
      </Card>
      <Card title="Audit log (latest 50)">
        <ul className="max-h-80 overflow-auto text-xs space-y-1">{audit.map((a) => <li key={a.id}><span className="muted">{new Date(a.at).toLocaleString()}</span> {a.action} {a.entity} {a.detail}</li>)}</ul>
      </Card>
    </div>
  );
}
