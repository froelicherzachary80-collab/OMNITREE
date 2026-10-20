import { useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonPicker } from '../components/common';
import { NeighborhoodGraph } from '../components/NeighborhoodGraph';
import { navigate } from '../app/router';

/** Whole-workspace graph explorer. Renders a bounded neighbourhood, never every node at once. */
export default function WorldTree() {
  const { graph, persons, selectedId, select, workspace } = useStore();
  const [hops, setHops] = useState(3);
  const [maxNodes, setMaxNodes] = useState(250);
  const [category, setCategory] = useState<'all' | 'family' | 'historical' | 'traditional'>('all');
  const focus = selectedId ?? workspace?.rootPersonId ?? persons[0]?.id;
  const counts = useMemo(() => ({
    historical: persons.filter((p) => p.historical && !p.traditional).length,
    traditional: persons.filter((p) => p.traditional).length,
    components: countComponents(graph),
  }), [persons, graph]);
  const filtered = persons.filter((p) => category === 'all' || (category === 'historical' ? p.historical && !p.traditional : category === 'traditional' ? p.traditional : !p.historical && !p.traditional));
  return (
    <div className="space-y-4">
      <Card>
        <div className="grid gap-3 md:grid-cols-4">
          <PersonPicker label="Focus person" value={focus} onChange={(id) => id && select(id)} />
          <label className="text-sm">Hops: <b>{hops}</b><input type="range" min={1} max={8} value={hops} onChange={(e) => setHops(+e.target.value)} className="block w-full accent-emerald-500" /></label>
          <label className="text-sm">Max nodes: <b>{maxNodes}</b><input type="range" min={50} max={1000} step={50} value={maxNodes} onChange={(e) => setMaxNodes(+e.target.value)} className="block w-full accent-emerald-500" /></label>
          <label className="text-sm">Category<select className="input mt-1" value={category} onChange={(e) => setCategory(e.target.value as typeof category)}><option value="all">All</option><option value="family">Private family tree</option><option value="historical">Historical (sourced public)</option><option value="traditional">Traditional / legendary</option></select></label>
        </div>
        <p className="mt-2 text-sm muted">{persons.length.toLocaleString()} people · {counts.components} disconnected branches · {counts.historical} historical · {counts.traditional} traditional-narrative profiles. Traditional narratives are not treated as verified lineage.</p>
      </Card>
      {focus && <Card title="World family graph"><NeighborhoodGraph graph={graph} focusId={focus} hops={hops} maxNodes={maxNodes} onSelect={select} height={560} /><div className="mt-2 flex gap-2"><button className="btn" onClick={() => navigate('tree')}>Open selected in tree</button></div></Card>}
      <Card title={`People in category (${filtered.length})`}>
        <ul className="grid gap-1 text-sm sm:grid-cols-2 lg:grid-cols-3">{filtered.slice(0, 300).map((p) => <li key={p.id}><button className="link" onClick={() => select(p.id)}>{p.names[0]?.full || p.id}</button>{p.traditional && <span className="chip chip-inf ml-1">traditional</span>}</li>)}</ul>
        {filtered.length > 300 && <p className="text-xs muted mt-2">Showing 300 of {filtered.length}. Use search to find others.</p>}
      </Card>
    </div>
  );
}

function countComponents(g: ReturnType<typeof useStore>['graph']) {
  const seen = new Set<string>();
  let n = 0;
  for (const id of g.persons.keys()) {
    if (seen.has(id)) continue;
    n++;
    const stack = [id];
    seen.add(id);
    while (stack.length) {
      const cur = stack.pop()!;
      for (const x of [...g.parents(cur), ...g.children(cur), ...g.partners(cur)]) if (!seen.has(x.personId)) { seen.add(x.personId); stack.push(x.personId); }
    }
  }
  return n;
}
