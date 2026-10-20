import { useEffect, useRef } from 'react';
import cytoscape from 'cytoscape';
import { displayName, type ID } from '../database/types';
import type { FamilyGraph } from '../genealogy/graph/familyGraph';
import { isBiological } from '../genealogy/graph/familyGraph';

/** Interactive relationship graph around a focus person (bounded BFS so huge trees stay responsive). */
export function NeighborhoodGraph({ graph, focusId, hops = 2, maxNodes = 200, onSelect, highlight = [], height = 460 }: { graph: FamilyGraph; focusId: ID; hops?: number; maxNodes?: number; onSelect: (id: ID) => void; highlight?: ID[]; height?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!ref.current) return;
    const nodes = new Set<ID>([focusId, ...highlight]);
    let frontier = [focusId];
    for (let h = 0; h < hops && nodes.size < maxNodes; h++) {
      const next: ID[] = [];
      for (const id of frontier) for (const n of [...graph.parents(id), ...graph.children(id), ...graph.partners(id)]) {
        if (nodes.size >= maxNodes) break;
        if (!nodes.has(n.personId)) { nodes.add(n.personId); next.push(n.personId); }
      }
      frontier = next;
    }
    const els: cytoscape.ElementDefinition[] = [];
    for (const id of nodes) {
      const p = graph.persons.get(id);
      if (!p) continue;
      els.push({ data: { id, label: displayName(p), sex: p.sex ?? 'U', focus: id === focusId ? 1 : 0, hl: highlight.includes(id) ? 1 : 0 } });
    }
    const seen = new Set<string>();
    for (const id of nodes) {
      for (const c of graph.children(id)) if (nodes.has(c.personId)) els.push({ data: { id: `pc-${id}-${c.personId}`, source: id, target: c.personId, kind: isBiological(c.relation) ? 'bio' : 'other' } });
      for (const pt of graph.partners(id)) {
        const k = [id, pt.personId].sort().join('|');
        if (nodes.has(pt.personId) && !seen.has(k)) { seen.add(k); els.push({ data: { id: `pp-${k}`, source: id, target: pt.personId, kind: 'partner' } }); }
      }
    }
    const dark = document.documentElement.classList.contains('dark');
    const cy = cytoscape({
      container: ref.current, elements: els, wheelSensitivity: 0.3,
      layout: { name: 'breadthfirst', directed: true, spacingFactor: 1.1, roots: els.filter((e) => !e.data.source && graph.parents(e.data.id!).every((p) => !nodes.has(p.personId))).map((e) => `#${CSS.escape(e.data.id!)}`).join(',') || undefined } as cytoscape.LayoutOptions,
      style: [
        { selector: 'node', style: { label: 'data(label)', 'font-size': 10, color: dark ? '#e8ecf5' : '#13213f', 'text-valign': 'bottom', 'text-margin-y': 4, width: 22, height: 22, 'background-color': '#3b82f6', 'border-width': 2, 'border-color': dark ? '#0e1931' : '#fff' } },
        { selector: 'node[sex = "F"]', style: { 'background-color': '#10b981' } },
        { selector: 'node[sex = "U"], node[sex = "X"]', style: { 'background-color': '#94a3b8' } },
        { selector: 'node[hl = 1]', style: { 'border-color': '#e5c062', 'border-width': 4 } },
        { selector: 'node[focus = 1]', style: { width: 32, height: 32, 'border-color': '#e5c062', 'border-width': 4 } },
        { selector: 'edge', style: { width: 2, 'line-color': dark ? '#33507f' : '#c8bfa8', 'curve-style': 'bezier', 'target-arrow-shape': 'triangle', 'target-arrow-color': dark ? '#33507f' : '#c8bfa8' } },
        { selector: 'edge[kind = "other"]', style: { 'line-style': 'dashed', 'line-color': '#e5c062', 'target-arrow-color': '#e5c062' } },
        { selector: 'edge[kind = "partner"]', style: { 'line-style': 'dotted', 'target-arrow-shape': 'none' } },
      ],
    });
    cy.on('tap', 'node', (e) => onSelect(e.target.id()));
    return () => cy.destroy();
  }, [graph, focusId, hops, maxNodes, highlight.join(','), onSelect]);
  return <div ref={ref} style={{ height }} className="panel-2 w-full" role="img" aria-label="Relationship graph. Solid: biological, dashed gold: adoptive/step, dotted: partners." />;
}
