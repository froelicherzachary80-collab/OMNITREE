import { useState } from 'react';
import { useStore } from '../app/store';
import { Card, download, Empty, PersonLink, PersonPicker, Progress } from '../components/common';
import { runDnaJob } from '../dna/workers/client';
import type { ParsedKit } from '../dna/parsers/genotype';
import { addDnaKit, deleteDnaKit, readKitVariants, reassignDnaKit } from '../database/repo';
import type { DnaKit, VariantCall } from '../database/types';
import { CHROMOSOME_ORDER } from '../dna/normalization/normalize';
import type { KitComparison } from '../dna/comparisons/compare';
import type { ibsSummary } from '../dna/comparisons/compare';
import { displayName } from '../database/types';

const PROVIDER: Record<string, string> = { ancestrydna: 'AncestryDNA', '23andme': '23andMe', unknown: 'Unknown provider' };

export default function DnaPage() {
  const { kits, workspace } = useStore();
  return (
    <div className="space-y-4">
      <div className="panel-2 p-3 text-sm">🔒 DNA files are processed only in this browser (Web Worker) and stored locally{workspace?.vaultEnabled ? ', encrypted with your vault key' : ' — enable a vault passphrase in Settings to encrypt them'}. Nothing is uploaded.</div>
      <Upload />
      {kits.length ? <><KitList /><Compare /><VariantSearch /></> : <Empty title="No DNA kits yet">Upload an AncestryDNA or 23andMe raw data file (.txt or .zip).</Empty>}
    </div>
  );
}

function Upload() {
  const store = useStore();
  const [owner, setOwner] = useState<string>();
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [parsed, setParsed] = useState<{ kit: ParsedKit; name: string }>();
  const needsUnlock = store.workspace?.vaultEnabled && !store.vaultKey;
  const onFile = async (f: File) => {
    setErr(''); setParsed(undefined); setBusy(true);
    try { setParsed({ kit: await runDnaJob<ParsedKit>({ kind: 'parse', fileName: f.name, bytes: await f.arrayBuffer() }), name: f.name }); }
    catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };
  const save = async () => {
    if (!parsed || !owner || !store.workspace) return;
    setBusy(true);
    try {
      await addDnaKit(store.workspace.id, owner, parsed.name, parsed.kit, store.vaultKey, 'User confirmed ownership or consent at upload');
      store.toast('DNA kit saved'); setParsed(undefined); await store.reload();
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };
  return (
    <Card title="Upload raw DNA data">
      <div className="grid gap-3 md:grid-cols-2">
        <PersonPicker label="Kit owner (required)" value={owner} onChange={setOwner} />
        <label className="text-sm">Raw genotype file<input type="file" accept=".txt,.csv,.tsv,.zip" className="input mt-1" onChange={(e) => e.target.files?.[0] && onFile(e.target.files[0])} data-testid="dna-file" /></label>
      </div>
      <label className="mt-2 flex gap-2 text-sm"><input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} /> This is my DNA, or the owner has consented to it being processed here. Processing consent is not permission to publish.</label>
      {needsUnlock && <p className="text-sm text-amber-500 mt-2">Unlock your vault in Settings before saving so the kit is stored encrypted.</p>}
      {busy && <div className="mt-3"><Progress label="Processing DNA" /></div>}
      {err && <div role="alert" className="mt-2 text-sm text-red-500">{err}</div>}
      {parsed && <div className="mt-3 space-y-2"><KitReport kit={parsed.kit} name={parsed.name} /><button className="btn btn-primary" disabled={!owner || !consent || busy || !!needsUnlock} onClick={save} data-testid="save-kit">Link kit to {owner ? displayName(store.graph.persons.get(owner)) : '…'} and save</button></div>}
    </Card>
  );
}

function KitReport({ kit, name }: { kit: ParsedKit; name: string }) {
  return (
    <div className="panel-2 p-3 text-sm">
      <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
        <div><div className="label">Provider</div>{PROVIDER[kit.provider]}</div>
        <div><div className="label">File</div>{name}</div>
        <div><div className="label">Genome build</div>{kit.build ?? 'Not stated in file'}</div>
        <div><div className="label">Variants</div>{kit.variants.length.toLocaleString()}</div>
        <div><div className="label">No-calls</div>{kit.noCallCount.toLocaleString()}</div>
        <div><div className="label">Invalid rows</div>{kit.invalidRows.length}</div>
        <div><div className="label">Duplicates</div>{kit.duplicateCount}</div>
        <div><div className="label">Call rate</div>{((1 - kit.noCallCount / kit.variants.length) * 100).toFixed(2)}%</div>
      </div>
      {kit.buildEvidence && <div className="mt-1 text-xs muted">Build evidence: “{kit.buildEvidence.slice(0, 120)}”</div>}
      {kit.invalidRows.length > 0 && <details className="mt-1 text-xs"><summary>Invalid row details</summary>{kit.invalidRows.slice(0, 20).map((r) => <div key={r.line}>line {r.line}: {r.reason}</div>)}</details>}
      <ChromosomeBars counts={kit.chromosomeCounts} />
    </div>
  );
}

function ChromosomeBars({ counts }: { counts: Record<string, number> }) {
  const max = Math.max(1, ...Object.values(counts));
  return (
    <div className="mt-3" aria-label="Chromosome distribution">
      <div className="label mb-1">Chromosome distribution</div>
      <div className="flex h-28 items-end gap-[3px]">
        {CHROMOSOME_ORDER.map((c) => <div key={c} className="flex flex-1 flex-col items-center" title={`chr${c}: ${counts[c] ?? 0}`}><div className="w-full rounded-t bg-emerald-500/80" style={{ height: `${((counts[c] ?? 0) / max) * 90}px` }} /><div className="text-[9px] muted">{c}</div></div>)}
      </div>
    </div>
  );
}

function KitList() {
  const store = useStore();
  const [reassign, setReassign] = useState<DnaKit>();
  return (
    <Card title="DNA kits">
      <div className="overflow-auto"><table className="data">
        <thead><tr><th>Owner</th><th>Provider</th><th>File</th><th>Build</th><th>Variants</th><th>No-calls</th><th>Stored</th><th /></tr></thead>
        <tbody>{store.kits.map((k) => (
          <tr key={k.id}><td><PersonLink id={k.personId} showYears={false} /></td><td>{PROVIDER[k.provider]}</td><td>{k.fileName}</td><td>{k.build ?? '—'}</td><td>{k.variantCount.toLocaleString()}</td><td>{k.noCallCount.toLocaleString()}</td><td>{k.encrypted ? '🔒 encrypted' : 'plain'}</td>
            <td className="whitespace-nowrap"><button className="btn" onClick={() => setReassign(k)}>Re-link</button> <button className="btn btn-danger" onClick={async () => { if (confirm('Permanently delete this DNA kit?')) { await deleteDnaKit(k); await store.reload(); } }}>Delete</button></td></tr>
        ))}</tbody>
      </table></div>
      {reassign && <div className="mt-3 panel-2 p-3"><PersonPicker label={`Re-link ${reassign.fileName} to`} onChange={async (id) => { if (id) { await reassignDnaKit(reassign, id); setReassign(undefined); await store.reload(); } }} /></div>}
      <p className="mt-2 text-xs muted">Multiple kits for one person are separate sources for that person — never treated as different people.</p>
    </Card>
  );
}

function Compare() {
  const store = useStore();
  const [a, setA] = useState(store.kits[0]?.id ?? '');
  const [b, setB] = useState(store.kits[1]?.id ?? '');
  const [res, setRes] = useState<KitComparison>();
  const [ibs, setIbs] = useState<ReturnType<typeof ibsSummary>>();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const kitA = store.kits.find((k) => k.id === a), kitB = store.kits.find((k) => k.id === b);
  const run = async () => {
    if (!kitA || !kitB || a === b) return;
    setBusy(true); setErr(''); setRes(undefined); setIbs(undefined);
    try {
      const [va, vb] = await Promise.all([readKitVariants(kitA, store.vaultKey), readKitVariants(kitB, store.vaultKey)]);
      const A = { label: kitA.fileName, build: kitA.build, variants: va }, B = { label: kitB.fileName, build: kitB.build, variants: vb };
      setRes(await runDnaJob<KitComparison>({ kind: 'compare', a: A, b: B }));
      if (kitA.personId !== kitB.personId) setIbs(await runDnaJob({ kind: 'ibs', a: A, b: B }));
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };
  const label = (k: DnaKit) => `${displayName(store.graph.persons.get(k.personId))} — ${PROVIDER[k.provider]} (${k.fileName})`;
  return (
    <Card title="Kit comparison">
      <div className="grid gap-2 md:grid-cols-[1fr_1fr_auto]">
        <select className="input" value={a} onChange={(e) => setA(e.target.value)} aria-label="Kit A">{store.kits.map((k) => <option key={k.id} value={k.id}>{label(k)}</option>)}</select>
        <select className="input" value={b} onChange={(e) => setB(e.target.value)} aria-label="Kit B">{store.kits.map((k) => <option key={k.id} value={k.id}>{label(k)}</option>)}</select>
        <button className="btn btn-primary" onClick={run} disabled={busy || a === b || !kitB}>Compare</button>
      </div>
      {busy && <div className="mt-2"><Progress label="Comparing" /></div>}
      {err && <div role="alert" className="mt-2 text-sm text-red-500">{err}</div>}
      {res && (
        <div className="mt-3 space-y-3 text-sm">
          <div className={`panel-2 p-3 ${res.buildsCompatible === false ? 'border border-amber-500' : ''}`}>{res.buildNote}</div>
          <div className="grid grid-cols-2 gap-2 md:grid-cols-5">
            {[['Overlap', res.overlap], ['Only in A', res.onlyA], ['Only in B', res.onlyB], ['Both called', res.bothCalled], ['No-call in either', res.noCallEither], ['Concordant', res.concordant], ['Discordant', res.discordant], ['Strand-flip candidates', res.strandFlipCandidates], ['A/T or C/G sites', res.ambiguousStrandSites], ['Concordance', res.concordanceRate !== undefined ? (res.concordanceRate * 100).toFixed(3) + '%' : '—']].map(([k, v]) => <div key={k as string} className="panel-2 p-2"><div className="label">{k}</div><div className="font-semibold">{typeof v === 'number' ? v.toLocaleString() : v}</div></div>)}
          </div>
          <ul className="list-disc pl-5">{res.interpretation.map((s, i) => <li key={i}>{s}</li>)}</ul>
          {ibs && <div className="panel-2 p-3"><div className="label">Different owners — allele sharing (IBS)</div>IBS0 {ibs.ibs0.toLocaleString()} · IBS1 {ibs.ibs1.toLocaleString()} · IBS2 {ibs.ibs2.toLocaleString()} over {ibs.sites.toLocaleString()} sites<div className="text-xs muted mt-1">{ibs.note}</div></div>}
          {res.conflicts.length > 0 && <details><summary className="cursor-pointer">Conflict report ({res.conflicts.length}{res.discordant > res.conflicts.length ? ` of ${res.discordant}` : ''})</summary>
            <div className="max-h-72 overflow-auto"><table className="data"><thead><tr><th>SNP</th><th>Chr</th><th>Pos</th><th>Kit A</th><th>Kit B</th><th>Note</th></tr></thead><tbody>{res.conflicts.slice(0, 300).map((c) => <tr key={c.rsid}><td>{c.rsid}</td><td>{c.chrom}</td><td>{c.pos}</td><td>{c.a}</td><td>{c.b}</td><td>{c.note}</td></tr>)}</tbody></table></div></details>}
          <button className="btn" onClick={() => download('omnidna-comparison-summary.json', JSON.stringify({ kitA: kitA?.fileName, kitB: kitB?.fileName, ...res, conflicts: res.conflicts.map((c) => ({ rsid: c.rsid, note: c.note })) }, null, 2), 'application/json')}>Export analysis summary</button>
          <p className="text-xs muted">The exported summary omits genotype values.</p>
        </div>
      )}
    </Card>
  );
}

function VariantSearch() {
  const store = useStore();
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<{ kit: DnaKit; v?: VariantCall }[]>();
  const [err, setErr] = useState('');
  const search = async () => {
    setErr('');
    try {
      const id = q.trim().toLowerCase();
      setRows(await Promise.all(store.kits.map(async (kit) => ({ kit, v: (await readKitVariants(kit, store.vaultKey)).find((v) => v.rsid.toLowerCase() === id) }))));
    } catch (e) { setErr((e as Error).message); }
  };
  return (
    <Card title="SNP inspection">
      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); search(); }}><input className="input" placeholder="rsID, e.g. rs4477212" value={q} onChange={(e) => setQ(e.target.value)} aria-label="SNP identifier" /><button className="btn btn-primary">Look up</button></form>
      {err && <div role="alert" className="mt-2 text-sm text-red-500">{err}</div>}
      {rows && <table className="data mt-3"><thead><tr><th>Kit</th><th>Chr</th><th>Position</th><th>Genotype</th></tr></thead><tbody>{rows.map(({ kit, v }) => <tr key={kit.id}><td>{PROVIDER[kit.provider]} · {kit.fileName}</td><td>{v?.chrom ?? '—'}</td><td>{v?.pos ?? '—'}</td><td>{v ? v.genotype : 'not on this chip'}</td></tr>)}</tbody></table>}
      <p className="mt-2 text-xs muted">Genotypes are shown as reported (alleles sorted). OmniTree provides no medical interpretation.</p>
    </Card>
  );
}
