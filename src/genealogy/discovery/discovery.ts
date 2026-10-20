import { displayName, eventOf, type ID, type Person } from '../../database/types';
import { FamilyGraph } from '../graph/familyGraph';

/** Soundex for surname-variation matching. */
export function soundex(s: string): string {
  const a = s.toUpperCase().replace(/[^A-Z]/g, '');
  if (!a) return '';
  const codes: Record<string, string> = { B: '1', F: '1', P: '1', V: '1', C: '2', G: '2', J: '2', K: '2', Q: '2', S: '2', X: '2', Z: '2', D: '3', T: '3', L: '4', M: '5', N: '5', R: '6' };
  let out = a[0];
  let last = codes[a[0]] ?? '';
  for (const ch of a.slice(1)) {
    const c = codes[ch] ?? '';
    if (c && c !== last) out += c;
    if (ch !== 'H' && ch !== 'W') last = c;
  }
  return (out + '000').slice(0, 4);
}

function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  const dp = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let prev = dp[0];
    dp[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = dp[j];
      dp[j] = Math.min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1));
      prev = tmp;
    }
  }
  return dp[b.length];
}

const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z ]/g, '').trim();
const year = (p: Person, t: string) => eventOf(p, t)?.date?.sortYear;
const place = (p: Person, t: string) => norm(eventOf(p, t)?.place ?? '');

export interface DuplicateCandidate {
  a: ID; b: ID; score: number; reasons: string[]; conflicts: string[];
}

/**
 * Score possible duplicates. Names alone never qualify: a candidate needs
 * corroborating evidence (dates, places, or parents) and no hard conflicts.
 * Results are suggestions only — merging always requires user review.
 */
export function scoreDuplicate(g: FamilyGraph, a: Person, b: Person): DuplicateCandidate | undefined {
  const reasons: string[] = [];
  const conflicts: string[] = [];
  const na = a.names[0], nb = b.names[0];
  if (!na || !nb) return undefined;
  const ga = norm(na.given), gb = norm(nb.given), sa = norm(na.surname), sb = norm(nb.surname);
  let score = 0;
  if (sa && sa === sb) { score += 20; reasons.push('same surname'); }
  else if (sa && soundex(sa) === soundex(sb)) { score += 12; reasons.push('surname sounds alike (Soundex)'); }
  else return undefined;
  const firstA = ga.split(' ')[0] ?? '', firstB = gb.split(' ')[0] ?? '';
  if (ga && ga === gb) { score += 20; reasons.push('same given name'); }
  else if (firstA && firstA === firstB) { score += 14; reasons.push('same first given name'); }
  else if (firstA && firstB && levenshtein(firstA, firstB) <= 1) { score += 8; reasons.push('similar given name'); }
  else return undefined;

  if (a.sex && b.sex && a.sex !== 'U' && b.sex !== 'U' && a.sex !== b.sex) conflicts.push('different recorded sex');
  let corroboration = 0;
  for (const [t, label] of [['BIRT', 'birth'], ['DEAT', 'death']] as const) {
    const ya = year(a, t), yb = year(b, t);
    if (ya !== undefined && yb !== undefined) {
      const diff = Math.abs(ya - yb);
      if (diff === 0) { score += 20; corroboration++; reasons.push(`same ${label} year`); }
      else if (diff <= 2) { score += 10; corroboration++; reasons.push(`${label} years within ${diff}`); }
      else if (diff > 5) conflicts.push(`${label} years differ by ${diff}`);
    }
    const pa = place(a, t), pb = place(b, t);
    if (pa && pb && (pa === pb || pa.split(' ')[0] === pb.split(' ')[0])) { score += 8; corroboration++; reasons.push(`matching ${label} place`); }
  }
  const parentsA = new Set(g.parents(a.id).map((p) => norm(displayName(g.persons.get(p.personId)))));
  const parentNamesB = g.parents(b.id).map((p) => norm(displayName(g.persons.get(p.personId))));
  const sharedParents = parentNamesB.filter((n) => parentsA.has(n)).length;
  if (sharedParents) { score += 12 * sharedParents; corroboration++; reasons.push(`${sharedParents} parent name(s) match`); }
  // Siblings in the same family are not duplicates of each other.
  if (g.childFamilies(a.id).some((f) => f.children.some((c) => c.personId === b.id))) conflicts.push('recorded as siblings in the same family');
  if (g.partners(a.id).some((p) => p.personId === b.id)) conflicts.push('recorded as partners');

  if (conflicts.length || corroboration === 0) return undefined;
  return { a: a.id, b: b.id, score: Math.min(100, score), reasons, conflicts };
}

/** Blocked by surname Soundex + given-name initial so large trees stay tractable. */
export function findDuplicates(g: FamilyGraph, minScore = 50): DuplicateCandidate[] {
  const blocks = new Map<string, Person[]>();
  for (const p of g.persons.values()) {
    const sx = soundex(p.names[0]?.surname ?? '');
    if (!sx) continue;
    const key = sx + norm(p.names[0]?.given ?? '').charAt(0);
    (blocks.get(key) ?? blocks.set(key, []).get(key)!).push(p);
  }
  const out: DuplicateCandidate[] = [];
  for (const block of blocks.values()) {
    if (block.length > 2000) continue; // pathological block; skip rather than freeze
    for (let i = 0; i < block.length; i++) for (let j = i + 1; j < block.length; j++) {
      const c = scoreDuplicate(g, block[i], block[j]);
      if (c && c.score >= minScore) out.push(c);
    }
  }
  return out.sort((x, y) => y.score - x.score);
}

export interface ConsistencyIssue {
  personId: ID; kind: 'date-order' | 'parent-age' | 'lifespan' | 'missing-birth' | 'posthumous-birth' | 'cycle'; severity: 'warning' | 'error'; message: string;
}

/** Deterministic date/age plausibility checks. */
export function checkConsistency(g: FamilyGraph): ConsistencyIssue[] {
  const issues: ConsistencyIssue[] = [];
  for (const p of g.persons.values()) {
    const b = year(p, 'BIRT'), d = year(p, 'DEAT');
    const name = displayName(p);
    if (b === undefined) issues.push({ personId: p.id, kind: 'missing-birth', severity: 'warning', message: `${name} has no birth date` });
    if (b !== undefined && d !== undefined) {
      if (d < b) issues.push({ personId: p.id, kind: 'date-order', severity: 'error', message: `${name} died (${d}) before birth (${b})` });
      else if (d - b > 120) issues.push({ personId: p.id, kind: 'lifespan', severity: 'warning', message: `${name} lifespan of ${d - b} years is implausible` });
    }
    if (b === undefined) continue;
    for (const par of g.parents(p.id, true)) {
      const parent = g.persons.get(par.personId);
      if (!parent) continue;
      const pb = year(parent, 'BIRT'), pd = year(parent, 'DEAT');
      if (pb !== undefined) {
        const age = b - pb;
        if (age < 12) issues.push({ personId: p.id, kind: 'parent-age', severity: age < 0 ? 'error' : 'warning', message: `${displayName(parent)} was ${age} at ${name}'s birth` });
        else if (age > (parent.sex === 'F' ? 55 : 80)) issues.push({ personId: p.id, kind: 'parent-age', severity: 'warning', message: `${displayName(parent)} was ${age} at ${name}'s birth` });
      }
      if (pd !== undefined && b > pd + (parent.sex === 'M' ? 1 : 0)) {
        issues.push({ personId: p.id, kind: 'posthumous-birth', severity: 'warning', message: `${name} born ${b}, after parent ${displayName(parent)} died ${pd}` });
      }
    }
  }
  for (const id of g.findAncestryCycles()) issues.push({ personId: id, kind: 'cycle', severity: 'error', message: `${displayName(g.persons.get(id))} is recorded as their own ancestor` });
  return issues;
}

export interface ResearchLead { personId: ID; priority: number; task: string }

/** Generate research tasks from gaps in the tree. */
export function researchLeads(g: FamilyGraph, rootId?: ID, limit = 25): ResearchLead[] {
  const scope = rootId ? [rootId, ...g.ancestors(rootId).keys()] : [...g.persons.keys()];
  const leads: ResearchLead[] = [];
  for (const id of scope) {
    const p = g.persons.get(id);
    if (!p) continue;
    const name = displayName(p);
    const parents = g.parents(id);
    const cited = p.events.some((e) => e.citations.length > 0);
    if (parents.length === 0) leads.push({ personId: id, priority: 3, task: `Identify the parents of ${name}` });
    else if (parents.length === 1) leads.push({ personId: id, priority: 2, task: `Identify the second parent of ${name}` });
    if (!eventOf(p, 'BIRT')?.date) leads.push({ personId: id, priority: 2, task: `Find a birth record for ${name}` });
    if (!cited) leads.push({ personId: id, priority: 2, task: `Add a source citation for ${name}` });
    if (eventOf(p, 'BIRT') && !eventOf(p, 'BIRT')!.place) leads.push({ personId: id, priority: 1, task: `Record the birthplace of ${name}` });
  }
  return leads.sort((a, b) => b.priority - a.priority).slice(0, limit);
}
