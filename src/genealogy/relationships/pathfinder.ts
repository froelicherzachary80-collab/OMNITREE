import type { Confidence, ID, Person } from '../../database/types';
import { FamilyGraph, isBiological } from '../graph/familyGraph';

export type StepKind = 'parent' | 'child' | 'partner' | 'adoptive-parent' | 'adoptive-child' | 'step-parent' | 'step-child' | 'association';

export interface PathStep { from: ID; to: ID; kind: StepKind; familyId?: ID }

export interface BloodRelationship {
  /** Label describing B's relationship to A, e.g. "first cousin once removed". */
  label: string;
  commonAncestors: ID[];
  generationsFromA: number;
  generationsFromB: number;
  half: boolean;
  route: ID[]; // A ... common ancestor ... B
  confidence: Confidence;
}

export interface RelationshipResult {
  a: ID;
  b: ID;
  blood: BloodRelationship[];
  /** Shortest connection over all recorded links (marriage, adoption, step), when no blood path or as extra context. */
  otherPath?: { steps: PathStep[]; description: string; confidence: Confidence };
  found: boolean;
}

const ORD = ['zeroth', 'first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth', 'ninth', 'tenth'];
const ordinal = (n: number) => ORD[n] ?? `${n}th`;
const times = (n: number) => (n === 1 ? 'once' : n === 2 ? 'twice' : n === 3 ? 'thrice' : `${n} times`);
const greats = (n: number) => (n <= 0 ? '' : n === 1 ? 'great-' : `${n}× great-`);

function gendered(sex: Person['sex'] | undefined, m: string, f: string, n: string) {
  return sex === 'M' ? m : sex === 'F' ? f : n;
}

/** Name the relationship of B to A given generation distances to the common ancestor. */
export function relationshipLabel(dA: number, dB: number, sexB?: Person['sex'], half = false): string {
  const h = half ? 'half-' : '';
  if (dA === 0 && dB === 0) return 'same person';
  if (dA === 0) {
    const base = gendered(sexB, 'son', 'daughter', 'child');
    if (dB === 1) return base;
    return `${greats(dB - 2)}grand${base}`;
  }
  if (dB === 0) {
    const base = gendered(sexB, 'father', 'mother', 'parent');
    if (dA === 1) return base;
    return `${greats(dA - 2)}grand${base}`;
  }
  if (dA === 1 && dB === 1) return h + gendered(sexB, 'brother', 'sister', 'sibling');
  if (dA === 1) return `${h}${greats(dB - 3)}${dB > 2 ? 'grand-' : ''}${gendered(sexB, 'nephew', 'niece', 'nibling')}`.replace('-grand-', '-grand');
  if (dB === 1) return `${h}${greats(dA - 3)}${dA > 2 ? 'grand-' : ''}${gendered(sexB, 'uncle', 'aunt', 'parent’s sibling')}`.replace('-grand-', '-grand');
  const degree = Math.min(dA, dB) - 1;
  const removed = Math.abs(dA - dB);
  return `${h}${ordinal(degree)} cousin${removed ? ' ' + times(removed) + ' removed' : ''}`;
}

/** BFS upward recording one predecessor per ancestor (biological links only). */
function ancestorTree(g: FamilyGraph, id: ID): Map<ID, { d: number; via?: ID }> {
  const out = new Map<ID, { d: number; via?: ID }>([[id, { d: 0 }]]);
  const q: ID[] = [id];
  while (q.length) {
    const cur = q.shift()!;
    const d = out.get(cur)!.d;
    for (const p of g.parents(cur, true)) {
      if (!out.has(p.personId)) { out.set(p.personId, { d: d + 1, via: cur }); q.push(p.personId); }
    }
  }
  return out;
}

function chain(tree: Map<ID, { d: number; via?: ID }>, top: ID): ID[] {
  const path: ID[] = [];
  let cur: ID | undefined = top;
  while (cur !== undefined) { path.push(cur); cur = tree.get(cur)!.via; }
  return path.reverse(); // start ... top
}

/** Compute all blood relationships via lowest common ancestors, plus any non-blood path. */
export function findRelationship(g: FamilyGraph, a: ID, b: ID): RelationshipResult {
  const result: RelationshipResult = { a, b, blood: [], found: false };
  if (!g.persons.has(a) || !g.persons.has(b)) return result;
  const ta = ancestorTree(g, a);
  const tb = ancestorTree(g, b);
  const common = [...ta.keys()].filter((x) => tb.has(x));
  // Lowest common ancestors: remove any common ancestor whose descendant (via biological links) is also common.
  const commonSet = new Set(common);
  const lowest = common.filter((c) => !g.children(c, true).some((ch) => commonSet.has(ch.personId)));
  // Group couples: two LCAs who are partners and share the same distances form one relationship (full).
  const used = new Set<ID>();
  for (const c of lowest) {
    if (used.has(c)) continue;
    const dA = ta.get(c)!.d, dB = tb.get(c)!.d;
    const partner = g.partners(c).map((p) => p.personId).find((p) => lowest.includes(p) && !used.has(p) && ta.get(p)!.d === dA && tb.get(p)!.d === dB);
    used.add(c);
    if (partner) used.add(partner);
    const ancestors = partner ? [c, partner] : [c];
    const routeUp = chain(ta, c);
    const routeDown = chain(tb, c).reverse().slice(1);
    // Half relationship: the two lines descend from the ancestor through different families.
    let half = false;
    if (!partner && dA > 0 && dB > 0) {
      const famA = g.parents(routeUp[routeUp.length - 2], true).find((p) => p.personId === c)?.familyId;
      const famB = g.parents(routeDown[0], true).find((p) => p.personId === c)?.familyId;
      half = famA !== famB;
    }
    result.blood.push({
      label: relationshipLabel(dA, dB, g.persons.get(b)?.sex, half),
      commonAncestors: ancestors,
      generationsFromA: dA,
      generationsFromB: dB,
      half,
      route: [...routeUp, ...routeDown],
      confidence: 'inferred',
    });
  }
  result.blood.sort((x, y) => x.generationsFromA + x.generationsFromB - (y.generationsFromA + y.generationsFromB));
  const other = shortestAnyPath(g, a, b);
  if (other && (result.blood.length === 0 || other.steps.some((s) => s.kind !== 'parent' && s.kind !== 'child'))) {
    result.otherPath = { steps: other.steps, description: describeSteps(g, other.steps), confidence: 'inferred' };
  }
  result.found = result.blood.length > 0 || !!result.otherPath;
  return result;
}

/** BFS over every recorded link type; returns the shortest typed route. */
export function shortestAnyPath(g: FamilyGraph, a: ID, b: ID, maxSteps = 30): { steps: PathStep[] } | undefined {
  if (a === b) return { steps: [] };
  const prev = new Map<ID, PathStep>();
  const seen = new Set([a]);
  let frontier = [a];
  for (let depth = 0; depth < maxSteps && frontier.length; depth++) {
    const next: ID[] = [];
    for (const cur of frontier) {
      const edges: PathStep[] = [
        ...g.parents(cur).map((p) => ({ from: cur, to: p.personId, familyId: p.familyId, kind: (isBiological(p.relation) ? 'parent' : p.relation === 'adopted' ? 'adoptive-parent' : 'step-parent') as StepKind })),
        ...g.children(cur).map((c) => ({ from: cur, to: c.personId, familyId: c.familyId, kind: (isBiological(c.relation) ? 'child' : c.relation === 'adopted' ? 'adoptive-child' : 'step-child') as StepKind })),
        ...g.partners(cur).map((p) => ({ from: cur, to: p.personId, familyId: p.familyId, kind: 'partner' as StepKind })),
        ...(g.persons.get(cur)?.associations ?? []).map((x) => ({ from: cur, to: x.personId, kind: 'association' as StepKind })),
      ];
      for (const e of edges) {
        if (seen.has(e.to)) continue;
        seen.add(e.to);
        prev.set(e.to, e);
        if (e.to === b) {
          const steps: PathStep[] = [];
          let x: ID = b;
          while (x !== a) { const s = prev.get(x)!; steps.push(s); x = s.from; }
          return { steps: steps.reverse() };
        }
        next.push(e.to);
      }
    }
    frontier = next;
  }
  return undefined;
}

const STEP_TEXT: Record<StepKind, string> = {
  parent: 'parent', child: 'child', partner: 'partner/spouse', 'adoptive-parent': 'adoptive parent',
  'adoptive-child': 'adopted child', 'step-parent': 'step/foster parent', 'step-child': 'step/foster child', association: 'associate',
};

export function describeSteps(g: FamilyGraph, steps: PathStep[]): string {
  return steps.map((s) => `→ ${STEP_TEXT[s.kind]} (${g.persons.get(s.to)?.names[0]?.full ?? s.to})`).join(' ');
}
