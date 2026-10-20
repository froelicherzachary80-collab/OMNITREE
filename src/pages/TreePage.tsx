import { useState } from 'react';
import { useStore } from '../app/store';
import { Card, Empty, PersonPicker } from '../components/common';
import { DescendantChart, FanChart, PedigreeChart } from '../components/charts';
import { NeighborhoodGraph } from '../components/NeighborhoodGraph';
import { blankPerson, PersonProfile } from '../components/PersonProfile';
import { displayName, eventOf, type ID } from '../database/types';
import { dateLabel } from '../genealogy/gedcom/dates';
import { PersonLink } from '../components/common';

const VIEWS = ['Pedigree', 'Ancestors (fan)', 'Descendants', 'Relationship graph', 'Family group sheet', 'Generation timeline'] as const;

export default function TreePage() {
  const store = useStore();
  const { graph, selectedId, workspace, persons } = store;
  const [view, setView] = useState<(typeof VIEWS)[number]>('Pedigree');
  const [gens, setGens] = useState(4);
  const [rootOverride, setRootOverride] = useState<ID>();
  const root = rootOverride ?? workspace?.rootPersonId ?? selectedId ?? persons[0]?.id;
  const selected = selectedId ? graph.persons.get(selectedId) : undefined;

  const addFirst = async () => {
    const p = blankPerson(workspace!.id, 'New', 'Person');
    await store.editPerson(p);
    store.select(p.id);
  };
  if (!persons.length) return <Empty title="No people yet"><button className="btn btn-primary mt-3" onClick={addFirst}>Add first person</button></Empty>;
  return (
    <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
      <div className="space-y-4 min-w-0">
        <Card>
          <div className="grid gap-3 md:grid-cols-[1fr_auto_auto]">
            <PersonPicker label="Jump to person" value={selectedId} onChange={(id) => id && store.select(id)} testId="jump" />
            <label className="text-sm">Generations: <b>{gens}</b><input type="range" min={2} max={8} value={gens} onChange={(e) => setGens(Number(e.target.value))} className="block w-40 accent-emerald-500" aria-label="Generations" /></label>
            <div className="flex items-end gap-2">
              <button className="btn" disabled={!selectedId || selectedId === root} onClick={() => setRootOverride(selectedId)}>Make selected the chart root</button>
              <button className="btn" onClick={addFirst}>+ Person</button>
            </div>
          </div>
          <div className="mt-3 flex flex-wrap gap-1" role="tablist">
            {VIEWS.map((v) => <button key={v} role="tab" aria-selected={view === v} className={`btn ${view === v ? 'btn-primary' : ''}`} onClick={() => setView(v)}>{v}</button>)}
          </div>
        </Card>
        <Card title={`${view} — ${displayName(graph.persons.get(root!))}`}>
          {root && view === 'Pedigree' && <PedigreeChart graph={graph} rootId={root} generations={gens} onSelect={store.select} selectedId={selectedId} />}
          {root && view === 'Ancestors (fan)' && <FanChart graph={graph} rootId={root} generations={Math.min(gens, 7)} onSelect={store.select} selectedId={selectedId} />}
          {root && view === 'Descendants' && <DescendantChart graph={graph} rootId={root} generations={gens} onSelect={store.select} selectedId={selectedId} />}
          {root && view === 'Relationship graph' && <NeighborhoodGraph graph={graph} focusId={selectedId ?? root} hops={Math.min(gens, 4)} onSelect={store.select} />}
          {root && view === 'Family group sheet' && <FamilyGroupSheet id={selectedId ?? root} />}
          {root && view === 'Generation timeline' && <GenerationTimeline id={root} gens={gens} />}
          <p className="mt-2 text-xs muted">Dashed lines: adoptive/step links. Only the requested generations are rendered; use the slider or “make root” to explore further.</p>
        </Card>
      </div>
      <div className="min-w-0">
        <Card>{selected ? <PersonProfile person={selected} /> : <div className="muted text-sm">Select a person to view and edit their profile.</div>}</Card>
      </div>
    </div>
  );
}

function FamilyGroupSheet({ id }: { id: ID }) {
  const { graph } = useStore();
  const fams = graph.spouseFamilies(id);
  if (!fams.length) return <div className="muted text-sm">{displayName(graph.persons.get(id))} has no recorded partner families.</div>;
  return (
    <div className="space-y-4">
      {fams.map((f) => (
        <div key={f.id} className="panel-2 p-3">
          <div className="label">Family {f.gedcomId ?? ''}</div>
          <table className="data mt-1"><tbody>
            {f.partnerIds.map((p) => { const per = graph.persons.get(p)!; return <tr key={p}><td>Partner</td><td><PersonLink id={p} /></td><td className="muted">{eventOf(per, 'BIRT')?.place}</td></tr>; })}
            {f.events.map((e) => <tr key={e.id}><td>{e.type}</td><td>{dateLabel(e.date)}</td><td className="muted">{e.place}</td></tr>)}
            {f.children.map((c) => <tr key={c.personId}><td>Child{c.relation !== 'birth' ? ` (${c.relation})` : ''}</td><td><PersonLink id={c.personId} /></td><td className="muted">{eventOf(graph.persons.get(c.personId)!, 'BIRT')?.place}</td></tr>)}
          </tbody></table>
        </div>
      ))}
    </div>
  );
}

function GenerationTimeline({ id, gens }: { id: ID; gens: number }) {
  const { graph } = useStore();
  const anc = [...graph.ancestors(id, { maxDepth: gens - 1 })].map(([pid, d]) => ({ pid, d }));
  const rows = [{ pid: id, d: 0 }, ...anc].map((r) => { const p = graph.persons.get(r.pid)!; return { ...r, b: eventOf(p, 'BIRT')?.date?.sortYear, de: eventOf(p, 'DEAT')?.date?.sortYear }; }).filter((r) => r.b !== undefined);
  if (!rows.length) return <div className="muted text-sm">No dated ancestors.</div>;
  const min = Math.min(...rows.map((r) => r.b!)), max = Math.max(...rows.map((r) => r.de ?? r.b! + 1), new Date().getFullYear() > min + 300 ? min + 300 : new Date().getFullYear());
  const x = (y: number) => ((y - min) / (max - min || 1)) * 100;
  return (
    <div className="space-y-1">
      {rows.sort((a, b) => a.b! - b.b!).map((r) => (
        <div key={r.pid} className="grid grid-cols-[140px_1fr] items-center gap-2 text-xs">
          <div className="truncate"><PersonLink id={r.pid} showYears={false} /> <span className="muted">G{r.d}</span></div>
          <div className="relative h-4 rounded bg-black/10"><div className="absolute h-4 rounded bg-emerald-500/70" style={{ left: `${x(r.b!)}%`, width: `${Math.max(1, x(r.de ?? r.b! + 1) - x(r.b!))}%` }} title={`${r.b}–${r.de ?? '?'}`} /></div>
        </div>
      ))}
      <div className="flex justify-between text-xs muted pl-[148px]"><span>{min}</span><span>{max}</span></div>
    </div>
  );
}
