import { useEffect, useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { BasisChip, Card, PersonLink, PersonPicker } from '../components/common';
import { findRelationship } from '../genealogy/relationships/pathfinder';
import { NeighborhoodGraph } from '../components/NeighborhoodGraph';
import { linkEvidence } from '../ai/tools/genealogyTools';
import type { ID } from '../database/types';

export default function RelationshipsPage() {
  const { graph, workspace, selectedId, select } = useStore();
  const [a, setA] = useState<ID | undefined>(workspace?.rootPersonId);
  const [b, setB] = useState<ID | undefined>(selectedId !== workspace?.rootPersonId ? selectedId : undefined);
  useEffect(() => { if (!a && workspace?.rootPersonId) setA(workspace.rootPersonId); }, [workspace?.rootPersonId, a]);
  const r = useMemo(() => (a && b ? findRelationship(graph, a, b) : undefined), [graph, a, b]);
  const step = (from: ID, to: ID) => {
    const up = graph.parents(from).find((p) => p.personId === to);
    const down = graph.parents(to).find((p) => p.personId === from);
    const link = up ?? down;
    const child = up ? from : to;
    return link ? linkEvidence(graph, child, link.familyId).length > 0 : false;
  };
  return (
    <div className="space-y-4">
      <Card title="PathFinder">
        <div className="grid gap-3 md:grid-cols-[1fr_auto_1fr]">
          <PersonPicker label="Person A" value={a} onChange={setA} testId="rel-a" />
          <button className="btn self-end" onClick={() => { setA(b); setB(a); }} aria-label="Swap">⇄</button>
          <PersonPicker label="Person B" value={b} onChange={setB} testId="rel-b" />
        </div>
      </Card>
      {r && (
        <Card title="Result">
          {!r.found && <p data-testid="rel-result">No recorded path connects these two people.</p>}
          {r.blood.map((bl, i) => (
            <div key={i} className="panel-2 mb-3 p-3" data-testid="rel-result">
              <div className="text-lg"><PersonLink id={b!} showYears={false} /> is <PersonLink id={a!} showYears={false} />’s <b className="gold">{bl.label}</b></div>
              <div className="text-sm muted">{bl.generationsFromA} generation(s) from A, {bl.generationsFromB} from B to the common ancestor{bl.commonAncestors.length > 1 ? 's' : ''}: {bl.commonAncestors.map((c) => <span key={c} className="mr-2"><PersonLink id={c} /></span>)}</div>
              <ol className="mt-2 space-y-1 text-sm">{bl.route.map((id, k) => (
                <li key={id} className="flex flex-wrap items-center gap-2">
                  <span className="muted w-6">{k + 1}.</span><PersonLink id={id} />
                  {bl.commonAncestors.includes(id) && <span className="chip chip-doc">common ancestor</span>}
                  {k > 0 && <BasisChip basis={step(bl.route[k - 1], id) ? 'documented' : 'inferred'} />}
                </li>
              ))}</ol>
            </div>
          ))}
          {r.otherPath && (
            <div className="panel-2 p-3 text-sm">
              <div className="font-semibold">Connection through marriage / adoption / other recorded links</div>
              <ol className="mt-1 space-y-1">{r.otherPath.steps.map((s, k) => <li key={k}>{k + 1}. <span className="chip">{s.kind}</span> <PersonLink id={s.to} /></li>)}</ol>
              <p className="mt-1 text-xs muted">This is not a blood relationship.</p>
            </div>
          )}
          <p className="mt-2 text-xs muted">“Documented” means the parent–child link has a cited source; “Inferred” means it follows from recorded links without a citation. Relationships are computed, never assumed.</p>
          {a && b && <div className="mt-3"><NeighborhoodGraph graph={graph} focusId={a} hops={Math.max(...r.blood.map((x) => x.generationsFromA + x.generationsFromB), r.otherPath?.steps.length ?? 2)} maxNodes={150} onSelect={select} highlight={[b, ...(r.blood[0]?.route ?? [])]} height={380} /></div>}
        </Card>
      )}
    </div>
  );
}
