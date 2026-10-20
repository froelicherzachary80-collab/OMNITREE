import { useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonLink } from '../components/common';
import { dateLabel } from '../genealogy/gedcom/dates';

export default function TimelinePage() {
  const { persons, families, workspace, graph } = useStore();
  const [q, setQ] = useState('');
  const [onlyAncestors, setOnlyAncestors] = useState(false);
  const rows = useMemo(() => {
    const scope = onlyAncestors && workspace?.rootPersonId ? new Set([workspace.rootPersonId, ...graph.ancestors(workspace.rootPersonId).keys()]) : undefined;
    const out: { y: number; label: string; type: string; place?: string; personIds: string[]; cited: boolean }[] = [];
    for (const p of persons) {
      if (scope && !scope.has(p.id)) continue;
      for (const e of p.events) if (e.date?.sortYear !== undefined) out.push({ y: e.date.sortYear, label: dateLabel(e.date), type: e.type, place: e.place, personIds: [p.id], cited: e.citations.length > 0 });
    }
    for (const f of families) {
      if (scope && !f.partnerIds.some((x) => scope.has(x))) continue;
      for (const e of f.events) if (e.date?.sortYear !== undefined) out.push({ y: e.date.sortYear, label: dateLabel(e.date), type: e.type, place: e.place, personIds: f.partnerIds, cited: e.citations.length > 0 });
    }
    const t = q.toLowerCase();
    return out.filter((r) => !t || r.place?.toLowerCase().includes(t) || r.type.toLowerCase().includes(t) || r.personIds.some((id) => graph.persons.get(id)?.names[0]?.full.toLowerCase().includes(t))).sort((a, b) => a.y - b.y);
  }, [persons, families, q, onlyAncestors, workspace?.rootPersonId, graph]);
  const decades = new Map<number, typeof rows>();
  for (const r of rows.slice(0, 3000)) { const d = Math.floor(r.y / 10) * 10; (decades.get(d) ?? decades.set(d, []).get(d)!).push(r); }
  return (
    <div className="space-y-4">
      <Card>
        <div className="flex flex-wrap gap-3">
          <input className="input max-w-md" placeholder="Filter by name, place or event type" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Filter timeline" />
          <label className="text-sm flex items-center gap-2"><input type="checkbox" checked={onlyAncestors} onChange={(e) => setOnlyAncestors(e.target.checked)} /> Home person’s ancestors only</label>
        </div>
      </Card>
      <Card title={`${rows.length.toLocaleString()} dated events`}>
        <div className="space-y-4">{[...decades].map(([d, evs]) => (
          <div key={d}><div className="gold font-serif text-lg">{d}s</div>
            <ul className="ml-2 border-l border-[color:var(--border)] pl-4 text-sm space-y-1">{evs.map((r, i) => <li key={i}><span className="muted">{r.label}</span> · <b>{r.type}</b> · {r.personIds.map((id) => <span key={id} className="mr-1"><PersonLink id={id} showYears={false} /></span>)}{r.place ? <span className="muted"> · {r.place}</span> : null}{!r.cited && <span className="chip chip-miss ml-1">unsourced</span>}</li>)}</ul>
          </div>
        ))}</div>
        {rows.length > 3000 && <p className="text-xs muted mt-2">Showing the first 3,000 events. Filter to narrow down.</p>}
      </Card>
    </div>
  );
}
