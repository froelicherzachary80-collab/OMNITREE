import { useEffect, useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonLink } from '../components/common';
import { OmniMemory } from '../ai/memory/omniMemory';
import type { ResearchHypothesis } from '../database/types';

export default function LibraryPage() {
  const store = useStore();
  const { sources, persons, workspace, version } = store;
  const [hyps, setHyps] = useState<ResearchHypothesis[]>([]);
  const [q, setQ] = useState('');
  useEffect(() => { workspace && OmniMemory.hypotheses(workspace.id).then(setHyps); }, [workspace, version]);
  const citing = useMemo(() => {
    const m = new Map<string, Set<string>>();
    for (const p of persons) for (const e of p.events) for (const c of e.citations) (m.get(c.sourceId) ?? m.set(c.sourceId, new Set()).get(c.sourceId)!).add(p.id);
    return m;
  }, [persons]);
  const shown = sources.filter((s) => !q || s.title.toLowerCase().includes(q.toLowerCase()));
  return (
    <div className="space-y-4">
      <Card title={`Research hypotheses (${hyps.length})`}>
        <p className="text-sm muted mb-2">Hypotheses are stored separately from confirmed relationships. Confirming one does not edit the tree.</p>
        <div className="space-y-2">{hyps.map((h) => (
          <div key={h.id} className="panel-2 p-3 text-sm">
            <div className="flex flex-wrap items-center gap-2"><span className={`chip ${h.status === 'confirmed' ? 'chip-doc' : h.status === 'rejected' ? 'chip-miss' : 'chip-inf'}`}>{h.status}</span><b className="flex-1">{h.title}</b>
              <button className="btn" onClick={async () => { await OmniMemory.setHypothesisStatus(h, 'confirmed'); await store.reload(); }}>Confirm</button>
              <button className="btn" onClick={async () => { await OmniMemory.setHypothesisStatus(h, 'rejected'); await store.reload(); }}>Reject</button></div>
            <ul className="mt-1 list-disc pl-5 muted">{h.evidence.map((e, i) => <li key={i}>{e}</li>)}</ul>
            <div className="mt-1">{h.personIds.slice(0, 8).map((id) => <span key={id} className="mr-2"><PersonLink id={id} showYears={false} /></span>)}</div>
          </div>
        ))}</div>
        {!hyps.length && <p className="text-sm muted">Create hypotheses from OmniAI answers.</p>}
      </Card>
      <Card title={`Sources (${sources.length})`} actions={<input className="input" placeholder="Filter sources" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Filter sources" />}>
        <table className="data"><thead><tr><th>Title</th><th>Author</th><th>Cited by</th></tr></thead><tbody>
          {shown.map((s) => <tr key={s.id}><td>{s.title}{s.gedcomId && <span className="muted text-xs"> {s.gedcomId}</span>}</td><td>{s.author}</td><td>{[...(citing.get(s.id) ?? [])].slice(0, 6).map((id) => <span key={id} className="mr-2"><PersonLink id={id} showYears={false} /></span>)}{(citing.get(s.id)?.size ?? 0) > 6 && '…'}</td></tr>)}
        </tbody></table>
      </Card>
    </div>
  );
}
