import { useState } from 'react';
import { displayName, type ID } from '../database/types';
import type { FamilyGraph } from '../genealogy/graph/familyGraph';
import { lifespan } from './common';

interface ChartProps { graph: FamilyGraph; rootId: ID; generations: number; onSelect: (id: ID) => void; selectedId?: ID }

/** Ahnentafel layout: slot n has parents 2n (father) and 2n+1 (mother). Only requested generations are rendered. */
function ahnentafel(graph: FamilyGraph, rootId: ID, generations: number) {
  const slots = new Map<number, ID>([[1, rootId]]);
  for (let n = 1; n < 2 ** generations; n++) {
    const id = slots.get(n);
    if (!id) continue;
    const ps = graph.parents(id);
    const sex = (x: ID) => graph.persons.get(x)?.sex;
    const father = ps.find((p) => sex(p.personId) === 'M') ?? ps.find((p) => sex(p.personId) !== 'F');
    const mother = ps.find((p) => p !== father);
    if (father) slots.set(2 * n, father.personId);
    if (mother) slots.set(2 * n + 1, mother.personId);
  }
  return slots;
}

export function PedigreeChart({ graph, rootId, generations, onSelect, selectedId }: ChartProps) {
  const slots = ahnentafel(graph, rootId, generations);
  const BW = 170, BH = 46, GX = 30;
  const leaves = 2 ** (generations - 1);
  const height = Math.max(leaves * (BH + 8), 120);
  const width = generations * (BW + GX);
  const boxes: JSX.Element[] = [];
  const lines: JSX.Element[] = [];
  for (const [n, id] of slots) {
    const gen = Math.floor(Math.log2(n));
    if (gen >= generations) continue;
    const idx = n - 2 ** gen;
    const span = height / 2 ** gen;
    const x = gen * (BW + GX);
    const y = idx * span + span / 2 - BH / 2;
    const p = graph.persons.get(id);
    for (const childSlot of [2 * n, 2 * n + 1]) {
      if (!slots.has(childSlot) || gen + 1 >= generations) continue;
      const cIdx = childSlot - 2 ** (gen + 1);
      const cSpan = height / 2 ** (gen + 1);
      const cy = cIdx * cSpan + cSpan / 2;
      const rel = graph.parents(id).find((q) => q.personId === slots.get(childSlot))?.relation;
      lines.push(<path key={`l${childSlot}`} d={`M${x + BW},${y + BH / 2} C${x + BW + GX / 2},${y + BH / 2} ${x + BW + GX / 2},${cy} ${x + BW + GX},${cy}`} fill="none" stroke="var(--border)" strokeWidth={2} strokeDasharray={rel && rel !== 'birth' && rel !== 'unknown' ? '5 4' : undefined} />);
    }
    boxes.push(
      <g key={n} transform={`translate(${x},${y})`} onClick={() => onSelect(id)} style={{ cursor: 'pointer' }} role="button" aria-label={displayName(p)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && onSelect(id)}>
        <rect width={BW} height={BH} rx={10} fill="var(--panel-2)" stroke={id === selectedId ? 'var(--gold)' : p?.sex === 'F' ? '#10b98199' : p?.sex === 'M' ? '#3b82f699' : 'var(--border)'} strokeWidth={id === selectedId ? 2.5 : 1.5} />
        <text x={10} y={19} fontSize={12.5} fontWeight={600} fill="var(--text)">{truncate(displayName(p), 22)}</text>
        <text x={10} y={35} fontSize={11} fill="var(--muted)">{lifespan(p)}{graph.parents(id).length === 0 ? ' · no parents recorded' : ''}</text>
      </g>,
    );
  }
  return (
    <div className="overflow-auto" style={{ touchAction: 'pan-x pan-y' }}>
      <svg width={width} height={height} role="img" aria-label="Pedigree chart">{lines}{boxes}</svg>
    </div>
  );
}

const truncate = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + '…' : s);

export function FanChart({ graph, rootId, generations, onSelect, selectedId }: ChartProps) {
  const slots = ahnentafel(graph, rootId, generations);
  const R0 = 50, RW = 55;
  const size = 2 * (R0 + RW * (generations - 1)) + 20;
  const c = size / 2;
  const arcs: JSX.Element[] = [];
  for (const [n, id] of slots) {
    const gen = Math.floor(Math.log2(n));
    if (gen >= generations) continue;
    const p = graph.persons.get(id);
    if (gen === 0) {
      arcs.push(<g key={n} onClick={() => onSelect(id)} style={{ cursor: 'pointer' }}><circle cx={c} cy={c} r={R0} fill="var(--panel-2)" stroke="var(--gold)" /><text x={c} y={c} textAnchor="middle" fontSize={11} fill="var(--text)">{truncate(displayName(p), 14)}</text></g>);
      continue;
    }
    const idx = n - 2 ** gen;
    const a0 = Math.PI + (idx / 2 ** gen) * Math.PI, a1 = Math.PI + ((idx + 1) / 2 ** gen) * Math.PI;
    const r0 = R0 + RW * (gen - 1), r1 = r0 + RW;
    const pt = (r: number, a: number) => `${c + r * Math.cos(a)},${c + r * Math.sin(a)}`;
    const d = `M${pt(r0, a0)} A${r0},${r0} 0 0 1 ${pt(r0, a1)} L${pt(r1, a1)} A${r1},${r1} 0 0 0 ${pt(r1, a0)} Z`;
    const am = (a0 + a1) / 2, rm = (r0 + r1) / 2;
    const deg = (am * 180) / Math.PI;
    arcs.push(
      <g key={n} onClick={() => onSelect(id)} style={{ cursor: 'pointer' }}>
        <path d={d} fill={p?.sex === 'F' ? '#10b98122' : '#3b82f622'} stroke={id === selectedId ? 'var(--gold)' : 'var(--border)'} strokeWidth={id === selectedId ? 2 : 1} />
        <text transform={`translate(${c + rm * Math.cos(am)},${c + rm * Math.sin(am)}) rotate(${gen > 2 ? deg : deg + 90})`} textAnchor="middle" fontSize={gen > 3 ? 8 : 10} fill="var(--text)">{truncate(displayName(p), gen > 3 ? 12 : 16)}</text>
      </g>,
    );
  }
  return <div className="overflow-auto"><svg width={size} height={size / 2 + R0 + 10} viewBox={`0 0 ${size} ${size / 2 + R0 + 10}`} role="img" aria-label="Fan chart">{arcs}</svg></div>;
}

/** Collapsible descendant tree; children render lazily when expanded. */
export function DescendantChart({ graph, rootId, generations, onSelect, selectedId }: ChartProps) {
  return <ul className="text-sm">{<DescNode graph={graph} id={rootId} depth={0} max={generations} onSelect={onSelect} selectedId={selectedId} />}</ul>;
}

function DescNode({ graph, id, depth, max, onSelect, selectedId, rel }: { graph: FamilyGraph; id: ID; depth: number; max: number; onSelect: (id: ID) => void; selectedId?: ID; rel?: string }) {
  const [open, setOpen] = useState(depth < max - 1);
  const p = graph.persons.get(id);
  const fams = graph.spouseFamilies(id);
  const hasKids = fams.some((f) => f.children.length);
  return (
    <li className="ml-3 border-l border-[color:var(--border)] pl-3 py-0.5">
      <div className="flex items-center gap-1">
        {hasKids ? <button aria-label={open ? 'Collapse' : 'Expand'} className="w-6 muted" onClick={() => setOpen(!open)}>{open ? '▾' : '▸'}</button> : <span className="w-6" />}
        <button className={`text-left ${id === selectedId ? 'gold font-semibold' : ''}`} onClick={() => onSelect(id)}>{displayName(p)} <span className="muted">{lifespan(p)}</span></button>
        {rel && rel !== 'birth' && <span className="chip chip-inf ml-1">{rel}</span>}
      </div>
      {open && fams.map((f) => (
        <div key={f.id}>
          {f.partnerIds.filter((x) => x !== id).map((sp) => <div key={sp} className="ml-7 text-xs muted">⚭ <button className="link" onClick={() => onSelect(sp)}>{displayName(graph.persons.get(sp))}</button></div>)}
          <ul>{f.children.map((c) => <DescNode key={c.personId} graph={graph} id={c.personId} depth={depth + 1} max={max} onSelect={onSelect} selectedId={selectedId} rel={c.relation} />)}</ul>
        </div>
      ))}
    </li>
  );
}
