import { useState } from 'react';
import { useStore } from '../app/store';
import { Card, download, Progress } from '../components/common';
import { parseGedcom, type ParsedGedcom } from '../genealogy/gedcom/parser';
import { exportGedcom } from '../genealogy/gedcom/exporter';
import { commitImport, exportWorkspaceJson, importWorkspaceJson, rollbackImport } from '../database/repo';
import { newId } from '../database/types';
import { isZip, readZip } from '../exports/zip';
import { findDuplicates } from '../genealogy/discovery/discovery';
import { FamilyGraph } from '../genealogy/graph/familyGraph';
import { openWithPassphrase, sealWithPassphrase } from '../security/crypto';
import { getDb } from '../database/db';

export default function ImportExportPage() {
  const store = useStore();
  const [preview, setPreview] = useState<{ parsed: ParsedGedcom; name: string; importId: string; crossDups: number }>();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [redact, setRedact] = useState(true);
  const [includeDna, setIncludeDna] = useState(false);
  const [pass, setPass] = useState('');

  const onFile = async (f: File) => {
    setErr(''); setBusy(true); setPreview(undefined);
    try {
      let bytes: Uint8Array = new Uint8Array(await f.arrayBuffer());
      if (isZip(bytes)) {
        const ged = (await readZip(bytes)).find((e) => /\.ged$/i.test(e.name));
        if (!ged) throw new Error('GEDZIP archive has no .ged file');
        bytes = ged.data;
      }
      const importId = newId('imp');
      const parsed = parseGedcom(new TextDecoder().decode(bytes), { workspaceId: store.workspace!.id, importId });
      const combined = new FamilyGraph([...store.persons, ...parsed.persons], [...store.families, ...parsed.families]);
      const newIds = new Set(parsed.persons.map((p) => p.id));
      const crossDups = store.persons.length ? findDuplicates(combined).filter((d) => newIds.has(d.a) !== newIds.has(d.b)).length : 0;
      setPreview({ parsed, name: f.name, importId, crossDups });
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };
  const commit = async () => {
    if (!preview) return;
    setBusy(true);
    try { await commitImport(store.workspace!.id, preview.importId, preview.name, preview.parsed); setPreview(undefined); await store.reload(); store.toast('Import committed'); }
    catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };
  const exportGed = () => {
    download(`${store.workspace!.name}.ged`, exportGedcom({ persons: store.persons, families: store.families, sources: store.sources, redactLiving: redact }), 'text/plain');
  };
  const backup = async () => {
    setErr('');
    try {
      const json = await exportWorkspaceJson(store.workspace!.id, { includeDna });
      if (pass.length < 8) throw new Error('Choose a backup passphrase of at least 8 characters');
      download(`omnitree-backup-${new Date().toISOString().slice(0, 10)}.omnitree.json`, JSON.stringify(await sealWithPassphrase(pass, json)), 'application/json');
    } catch (e) { setErr((e as Error).message); }
  };
  const restore = async (f: File) => {
    setErr('');
    try {
      let text = await f.text();
      const obj = JSON.parse(text);
      if (obj.format === 'omnitree-encrypted') text = await openWithPassphrase(prompt('Backup passphrase') ?? '', obj);
      const id = await importWorkspaceJson(text);
      await store.openWorkspace(id);
      store.toast('Backup restored');
    } catch (e) { setErr((e as Error).message); }
  };
  const counts = (lvl: string) => preview?.parsed.diagnostics.filter((d) => d.level === lvl).length ?? 0;

  return (
    <div className="space-y-4">
      {err && <div role="alert" className="panel border-red-500 p-3 text-sm text-red-500">{err}</div>}
      <Card title="Import GEDCOM">
        <p className="text-sm muted">Supports GEDCOM 5.5, 5.5.1, 7.x and GEDZIP. You review a preview before anything is written; each import can be rolled back.</p>
        <input type="file" accept=".ged,.gdz,.zip" className="input mt-2" onChange={(e) => e.target.files?.[0] && onFile(e.target.files[0])} data-testid="ged-file" />
        {busy && <div className="mt-2"><Progress label="Working" /></div>}
        {preview && (
          <div className="mt-3 space-y-3" data-testid="ged-preview">
            <div className="grid grid-cols-2 gap-2 text-sm md:grid-cols-5">
              {[['Version', preview.parsed.version ?? 'unknown'], ['Individuals', preview.parsed.persons.length], ['Families', preview.parsed.families.length], ['Sources', preview.parsed.sources.length], ['Possible duplicates with existing', preview.crossDups]].map(([k, v]) => <div key={k as string} className="panel-2 p-2"><div className="label">{k}</div><b>{v}</b></div>)}
            </div>
            <div className="text-sm">Diagnostics: <span className="chip chip-miss">{counts('error')} errors</span> <span className="chip chip-inf">{counts('warning')} warnings</span> <span className="chip">{counts('info')} info</span></div>
            <div className="panel-2 max-h-56 overflow-auto p-2 text-xs">{preview.parsed.diagnostics.map((d, i) => <div key={i}><b>{d.level}</b>{d.line ? ` line ${d.line}` : ''}: {d.message}</div>)}</div>
            <div className="flex gap-2"><button className="btn btn-primary" onClick={commit} disabled={busy} data-testid="commit-import">Commit import</button><button className="btn" onClick={() => setPreview(undefined)}>Cancel</button></div>
            <p className="text-xs muted">Duplicates are never merged automatically; review them in Discover Ancestors.</p>
          </div>
        )}
      </Card>
      <Card title="Import history">
        <table className="data"><thead><tr><th>File</th><th>Version</th><th>People</th><th>Date</th><th>Status</th><th /></tr></thead><tbody>
          {store.imports.map((i) => <tr key={i.id}><td>{i.fileName}</td><td>{i.version}</td><td>{i.personCount}</td><td>{new Date(i.importedAt).toLocaleString()}</td><td>{i.status}</td>
            <td>{i.status === 'committed' && <button className="btn btn-danger" onClick={async () => { if (!confirm(`Roll back ${i.fileName}? All its people, families and sources are removed.`)) return; try { await rollbackImport(i.id); await store.reload(); } catch (e) { setErr((e as Error).message); } }}>Roll back</button>}</td></tr>)}
        </tbody></table>
      </Card>
      <Card title="Export">
        <div className="space-y-3">
          <div className="flex flex-wrap items-center gap-3"><button className="btn btn-primary" onClick={exportGed} disabled={!store.persons.length}>Export GEDCOM 5.5.1</button><label className="text-sm"><input type="checkbox" checked={redact} onChange={(e) => setRedact(e.target.checked)} /> Redact living-private people</label></div>
          <div className="panel-2 space-y-2 p-3">
            <div className="font-semibold">Encrypted backup</div>
            <input type="password" className="input" placeholder="Backup passphrase (min 8 characters)" value={pass} onChange={(e) => setPass(e.target.value)} aria-label="Backup passphrase" autoComplete="new-password" />
            <label className="text-sm block"><input type="checkbox" checked={includeDna} onChange={(e) => setIncludeDna(e.target.checked)} /> Include DNA kits</label>
            <div className="flex flex-wrap gap-2"><button className="btn btn-primary" onClick={backup}>Download encrypted backup</button>
              <label className="btn cursor-pointer">Restore backup…<input type="file" accept=".json" className="hidden" onChange={(e) => e.target.files?.[0] && restore(e.target.files[0])} /></label>
              <button className="btn" onClick={async () => download('omnitree-audit-log.json', JSON.stringify(await getDb().audit.where('workspaceId').equals(store.workspace!.id).toArray(), null, 2), 'application/json')}>Export audit log</button></div>
            <p className="text-xs muted">Browsers can evict local data. Keep regular encrypted backups.</p>
          </div>
        </div>
      </Card>
    </div>
  );
}
