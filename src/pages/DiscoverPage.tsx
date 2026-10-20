import { useEffect, useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonLink } from '../components/common';
import { checkConsistency, findDuplicates, researchLeads, soundex, type DuplicateCandidate } from '../genealogy/discovery/discovery';
import { mergePersons, undoMerge } from '../database/repo';
import type { MergeRecord } from '../database/db';
import { OmniMemory } from '../ai/memory/omniMemory';
import { getDb } from '../database/db';
import { displayName, eventOf } from '../database/types';
import { dateLabel } from '../genealogy/gedcom/dates';

export default function DiscoverPage() {
  const store = useStore();
  const { graph, workspace, persons, version } = store;
  const [rejected, setRejected] = useState<Set<string>>(new Set());
  const [review, setReview] = useState<DuplicateCandidate>();
  const dups = useMemo(() => findDuplicates(graph), [graph]);
  const issues = useMemo(() => checkConsistency(graph).filter((i) => i.kind !== 'missing-birth'), [graph]);
  const leads = useMemo(() => researchLeads(graph, workspace?.rootPersonId, 40), [graph, workspace?.rootPersonId]);
  const variants = useMemo(() => {
    const m = new Map<string, Set<string>>();
    for (const p of persons) for (const n of p.names) if (n.surname) { const k = soundex(n.surname); (m.get(k) ?? m.set(k, new Set()).get(k)!).add(n.surname); }
    return [...m.values()].filter((s) => s.size > 1).map((s) => [...s]);
  }, [persons]);
  useEffect(() => {
    if (!workspace) return;
    getDb().memory.where('workspaceId').equals(workspace.id).filter((m) => m.kind === 'rejected-match').toArray().then((r) => setRejected(new Set(r.map((m) => [...m.personIds].sort().join('|')))));
  }, [workspace, version]);
  const visible = dups.filter((d) => !rejected.has([d.a, d.b].sort().join('|')));
  return (
    <div className="space-y-4">
      <Card title={`Possible duplicates (${visible.length})`}>
        <p className="text-sm muted mb-2">Suggestions require matching names plus corroborating dates, places or parents. Nothing is merged without your review.</p>
        <div className="space-y-2">{visible.slice(0, 50).map((d) => (
          <div key={d.a + d.b} className="panel-2 flex flex-wrap items-center gap-2 p-3 text-sm">
            <span className="chip chip-inf">{d.score}</span><PersonLink id={d.a} /> ↔ <PersonLink id={d.b} />
            <span className="muted flex-1">{d.reasons.join(' · ')}</span>
            <button className="btn" onClick={() => setReview(d)}>Review</button>
            <button className="btn" onClick={async () => { await OmniMemory.remember(workspace!.id, 'rejected-match', `${displayName(graph.persons.get(d.a))} ≠ ${displayName(graph.persons.get(d.b))}`, [d.a, d.b]); await store.reload(); }}>Not the same</button>
          </div>
        ))}</div>
      </Card>
      {review && <MergeReview d={review} onClose={() => setReview(undefined)} />}
      <MergeHistory />
      <Card title={`Date & age conflicts (${issues.length})`}>
        <ul className="space-y-1 text-sm">{issues.slice(0, 100).map((i, k) => <li key={k}><span className={`chip ${i.severity === 'error' ? 'chip-miss' : 'chip-inf'}`}>{i.kind}</span> <PersonLink id={i.personId} showYears={false} /> — {i.message}</li>)}</ul>
        {!issues.length && <p className="text-sm muted">No conflicts detected.</p>}
      </Card>
      <Card title="Research leads & missing links">
        <ul className="space-y-1 text-sm">{leads.map((l, k) => <li key={k}><PersonLink id={l.personId} showYears={false} />: {l.task}</li>)}</ul>
      </Card>
      <Card title="Surname variations (Soundex groups)">
        <div className="flex flex-wrap gap-2 text-sm">{variants.slice(0, 60).map((v) => <span key={v.join()} className="chip">{v.join(' · ')}</span>)}</div>
        {!variants.length && <p className="text-sm muted">No surname variants found.</p>}
        <p className="mt-2 text-xs muted">External record connectors (FamilySearch and public archives) are not connected in v0.1; leads come from your imported data only.</p>
      </Card>
    </div>
  );
}

function MergeReview({ d, onClose }: { d: DuplicateCandidate; onClose: () => void }) {
  const store = useStore();
  const a = store.graph.persons.get(d.a)!, b = store.graph.persons.get(d.b)!;
  const [keepA, setKeepA] = useState(true);
  const row = (label: string, f: (p: typeof a) => string) => <tr><td className="muted">{label}</td><td>{f(a)}</td><td>{f(b)}</td></tr>;
  return (
    <Card title="Merge review" actions={<button className="btn" onClick={onClose}>Close</button>}>
      <table className="data"><thead><tr><th /><th>A</th><th>B</th></tr></thead><tbody>
        {row('Name', displayName)}{row('Sex', (p) => p.sex ?? '')}
        {row('Birth', (p) => `${dateLabel(eventOf(p, 'BIRT')?.date)} ${eventOf(p, 'BIRT')?.place ?? ''}`)}
        {row('Death', (p) => `${dateLabel(eventOf(p, 'DEAT')?.date)} ${eventOf(p, 'DEAT')?.place ?? ''}`)}
        {row('Parents', (p) => store.graph.parents(p.id).map((x) => displayName(store.graph.persons.get(x.personId))).join(', '))}
        {row('Source', (p) => p.gedcomId ?? p.id)}
      </tbody></table>
      <div className="mt-3 flex flex-wrap items-center gap-3 text-sm">
        <label><input type="radio" checked={keepA} onChange={() => setKeepA(true)} /> Keep A as primary</label>
        <label><input type="radio" checked={!keepA} onChange={() => setKeepA(false)} /> Keep B as primary</label>
        <button className="btn btn-primary" onClick={async () => { await mergePersons(keepA ? a : b, keepA ? b : a); await OmniMemory.remember(store.workspace!.id, 'confirmed-match', `Merged ${displayName(a)} and ${displayName(b)}`, [d.a, d.b]); store.toast('Profiles merged — undo it under Merge history'); onClose(); await store.reload(); }}>Confirm merge</button>
      </div>
      <p className="mt-2 text-xs muted">Merging keeps all names, events, notes and citations from both profiles. It is recorded in the audit log; restore from backup to reverse.</p>
    </Card>
  );
}

function MergeHistory() {
  const store = useStore();
  const [rows, setRows] = useState<MergeRecord[]>([]);
  useEffect(() => { store.workspace && getDb().merges.where('workspaceId').equals(store.workspace.id).reverse().sortBy('at').then(setRows); }, [store.workspace, store.version]);
  if (!rows.length) return null;
  return (
    <Card title="Merge history">
      <ul className="space-y-2 text-sm">{rows.map((m) => (
        <li key={m.id} className="panel-2 flex flex-wrap items-center gap-2 p-2">
          <span className="flex-1">{new Date(m.at).toLocaleString()} — {m.before.persons.map((p) => displayName(p)).join(' + ')}</span>
          {m.undone ? <span className="chip">undone</span> : <button className="btn" onClick={async () => { try { await undoMerge(m.id); store.toast('Merge undone'); await store.reload(); } catch (e) { alert((e as Error).message); } }}>Undo merge</button>}
        </li>
      ))}</ul>
      <p className="mt-1 text-xs muted">Undo restores both profiles, their family links and DNA kit owners as they were just before the merge. Edits made to the merged profile afterwards are lost.</p>
    </Card>
  );
}
