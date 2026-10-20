import { useEffect, useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { navigate } from '../app/router';
import { Card, Empty, PersonLink, Stat } from '../components/common';
import { PedigreeChart } from '../components/charts';
import { findDuplicates, researchLeads } from '../genealogy/discovery/discovery';
import { toolEarliest } from '../ai/tools/genealogyTools';
import { getDb } from '../database/db';
import type { AuditEvent } from '../database/types';
import { OmniMemory } from '../ai/memory/omniMemory';

export function Home() {
  const { persons, families, graph, kits, sources, workspace, select, version } = useStore();
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [openQ, setOpenQ] = useState(0);
  useEffect(() => {
    if (!workspace) return;
    getDb().audit.where('workspaceId').equals(workspace.id).reverse().sortBy('at').then((a) => setAudit(a.slice(0, 8)));
    OmniMemory.hypotheses(workspace.id).then((h) => setOpenQ(h.filter((x) => x.status === 'open').length));
  }, [workspace, version]);
  const stats = useMemo(() => {
    const earliest = toolEarliest({ graph, sources: new Map() });
    const cited = persons.filter((p) => p.events.some((e) => e.citations.length)).length;
    return {
      generations: graph.maxGenerations(),
      earliest: earliest.personIds[0],
      dups: persons.length <= 20000 ? findDuplicates(graph).length : undefined,
      coverage: persons.length ? Math.round((cited / persons.length) * 100) : 0,
      leads: researchLeads(graph, workspace?.rootPersonId, 6),
    };
  }, [graph, persons, workspace?.rootPersonId]);
  const root = workspace?.rootPersonId ?? persons[0]?.id;

  if (!persons.length) return (
    <Empty title="Your tree is empty">
      Start by importing a GEDCOM file or adding your first person.
      <div className="mt-4 flex justify-center gap-2"><button className="btn btn-primary" onClick={() => navigate('io')}>Import GEDCOM</button><button className="btn" onClick={() => navigate('tree')}>Add a person</button></div>
    </Empty>
  );

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
        <Stat label="Individuals" value={persons.length.toLocaleString()} onClick={() => navigate('tree')} />
        <Stat label="Families" value={families.length.toLocaleString()} onClick={() => navigate('world')} />
        <Stat label="Known generations" value={stats.generations} hint="longest recorded line" />
        <Stat label="DNA kits" value={kits.length} onClick={() => navigate('dna')} />
        <Stat label="Possible duplicates" value={stats.dups ?? '—'} onClick={() => navigate('discover')} />
        <Stat label="Open research questions" value={openQ} onClick={() => navigate('library')} />
        <Stat label="Source coverage" value={`${stats.coverage}%`} hint={`${sources.length} sources; people with ≥1 citation`} onClick={() => navigate('library')} />
        <div className="col-span-2 md:col-span-3"><Stat label="Earliest dated ancestor" value={stats.earliest ? <PersonLink id={stats.earliest} /> : '—'} /></div>
      </div>
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="Family tree preview" className="lg:col-span-2" actions={<button className="btn" onClick={() => navigate('tree')}>Open tree</button>}>
          {root ? <PedigreeChart graph={graph} rootId={root} generations={4} onSelect={(id) => { select(id); navigate('tree'); }} /> : null}
          {!workspace?.rootPersonId && <p className="mt-2 text-xs muted">Tip: set your home person from their profile (“Set as home person”).</p>}
        </Card>
        <Card title="Suggested research tasks">
          <ul className="space-y-2 text-sm">{stats.leads.map((l, i) => <li key={i} className="panel-2 p-2"><PersonLink id={l.personId} showYears={false} /><div className="muted">{l.task}</div></li>)}</ul>
          {!stats.leads.length && <p className="muted text-sm">No gaps found.</p>}
        </Card>
      </div>
      <Card title="Recent changes">
        <ul className="text-sm space-y-1">{audit.map((a) => <li key={a.id}><span className="muted">{new Date(a.at).toLocaleString()}</span> — {a.action} {a.entity} {a.detail ? `· ${a.detail}` : ''}</li>)}</ul>
      </Card>
    </div>
  );
}
