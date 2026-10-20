import { displayName, eventOf, type ID, type Person, type Source } from '../../database/types';
import { FamilyGraph } from '../../genealogy/graph/familyGraph';
import { findRelationship } from '../../genealogy/relationships/pathfinder';
import { checkConsistency, findDuplicates, researchLeads } from '../../genealogy/discovery/discovery';
import { dateLabel } from '../../genealogy/gedcom/dates';

export type Basis = 'documented' | 'inferred' | 'missing';
export interface Fact { statement: string; basis: Basis; personIds: ID[]; sourceIds: ID[] }
export interface ToolResult { tool: string; summary: string; facts: Fact[]; personIds: ID[]; caveats: string[] }

export interface ToolContext { graph: FamilyGraph; sources: Map<ID, Source> }

const lifespan = (p: Person) => {
  const b = eventOf(p, 'BIRT')?.date, d = eventOf(p, 'DEAT')?.date;
  return b || d ? ` (${dateLabel(b) || '?'} – ${dateLabel(d) || ''})` : '';
};
const label = (g: FamilyGraph, id: ID) => { const p = g.persons.get(id); return p ? `${displayName(p)}${lifespan(p)} [${id}]` : id; };
const citedSources = (p?: Person) => [...new Set((p?.events ?? []).flatMap((e) => e.citations.map((c) => c.sourceId)).filter((s) => !s.startsWith('missing:')))];

/** Evidence for a parent-child link: citations on the child's birth and the family's events. */
export function linkEvidence(g: FamilyGraph, childId: ID, familyId: ID): ID[] {
  const child = g.persons.get(childId);
  const fam = g.families.get(familyId);
  const ids = [
    ...(eventOf(child!, 'BIRT')?.citations ?? []), ...(eventOf(child!, 'CHR')?.citations ?? []), ...(eventOf(child!, 'BAPM')?.citations ?? []),
    ...(child?.events.filter((e) => e.type === '_CITE').flatMap((e) => e.citations) ?? []),
    ...(fam?.events.flatMap((e) => e.citations) ?? []),
  ].map((c) => c.sourceId).filter((s) => !s.startsWith('missing:'));
  return [...new Set(ids)];
}

export function toolParentsGrandparents(ctx: ToolContext, id: ID): ToolResult {
  const g = ctx.graph;
  const facts: Fact[] = [];
  const ids: ID[] = [];
  for (const par of g.parents(id)) {
    const src = linkEvidence(g, id, par.familyId);
    ids.push(par.personId);
    facts.push({ statement: `Parent${par.relation !== 'birth' ? ` (${par.relation})` : ''}: ${label(g, par.personId)}`, basis: src.length ? 'documented' : 'inferred', personIds: [par.personId], sourceIds: src });
    for (const gp of g.parents(par.personId)) {
      const s2 = linkEvidence(g, par.personId, gp.familyId);
      ids.push(gp.personId);
      facts.push({ statement: `Grandparent via ${displayName(g.persons.get(par.personId))}: ${label(g, gp.personId)}`, basis: s2.length ? 'documented' : 'inferred', personIds: [gp.personId], sourceIds: s2 });
    }
  }
  const caveats = facts.length ? [] : [`No parents are recorded for ${displayName(g.persons.get(id))}.`];
  return { tool: 'parents_grandparents', summary: `${g.parents(id).length} parent(s) and ${facts.length - g.parents(id).length} grandparent(s) recorded for ${label(g, id)}.`, facts, personIds: ids, caveats };
}

export function toolAncestors(ctx: ToolContext, id: ID, line?: 'paternal' | 'maternal'): ToolResult {
  const g = ctx.graph;
  const anc = g.ancestors(id, { line });
  const rows = [...anc].sort((a, b) => a[1] - b[1]);
  const facts = rows.slice(0, 200).map(([pid, d]) => ({ statement: `Generation ${d}: ${label(g, pid)}`, basis: 'inferred' as Basis, personIds: [pid], sourceIds: citedSources(g.persons.get(pid)) }));
  return {
    tool: line ? `${line}_line` : 'ancestors',
    summary: `${anc.size} known ${line ? line + ' ' : ''}ancestor(s) of ${label(g, id)} across ${rows.length ? rows[rows.length - 1][1] : 0} generation(s).`,
    facts, personIds: rows.map((r) => r[0]),
    caveats: [line ? `The ${line} line is determined from the recorded sex of the first-generation parent.` : '', anc.size > 200 ? 'Only the first 200 are listed.' : '', 'Ancestry is inferred by chaining recorded parent-child links; each link’s own evidence applies.'].filter(Boolean),
  };
}

export function toolDescendants(ctx: ToolContext, id: ID): ToolResult {
  const g = ctx.graph;
  const desc = [...g.descendants(id)].sort((a, b) => a[1] - b[1]);
  return {
    tool: 'descendants', summary: `${desc.length} recorded descendant(s) of ${label(g, id)}.`,
    facts: desc.slice(0, 200).map(([pid, d]) => ({ statement: `Generation +${d}: ${label(g, pid)}`, basis: 'inferred', personIds: [pid], sourceIds: citedSources(g.persons.get(pid)) })),
    personIds: desc.map((d) => d[0]), caveats: desc.length > 200 ? ['Only the first 200 are listed.'] : [],
  };
}

export function toolPlaceSearch(ctx: ToolContext, place: string, scopeId?: ID): ToolResult {
  const g = ctx.graph;
  const needle = place.toLowerCase();
  const scope = scopeId ? [...g.ancestors(scopeId).keys()] : [...g.persons.keys()];
  const facts: Fact[] = [];
  for (const id of scope) {
    const p = g.persons.get(id)!;
    for (const e of p.events) if (e.place?.toLowerCase().includes(needle)) {
      facts.push({ statement: `${label(g, id)} — ${e.type} ${dateLabel(e.date)} at ${e.place}`, basis: e.citations.length ? 'documented' : 'inferred', personIds: [id], sourceIds: e.citations.map((c) => c.sourceId) });
    }
  }
  return { tool: 'place_search', summary: `${new Set(facts.map((f) => f.personIds[0])).size} ${scopeId ? 'ancestor(s)' : 'person(s)'} have recorded events in places matching "${place}".`, facts, personIds: [...new Set(facts.map((f) => f.personIds[0]))], caveats: facts.length ? [] : ['No matching place text was found. Places are matched by recorded text only.'] };
}

export function toolDuplicates(ctx: ToolContext): ToolResult {
  const g = ctx.graph;
  const d = findDuplicates(g);
  return {
    tool: 'duplicates', summary: `${d.length} possible duplicate pair(s) found. None are merged automatically.`,
    facts: d.slice(0, 50).map((c) => ({ statement: `${label(g, c.a)} ↔ ${label(g, c.b)} — score ${c.score}: ${c.reasons.join(', ')}`, basis: 'inferred', personIds: [c.a, c.b], sourceIds: [] })),
    personIds: d.flatMap((c) => [c.a, c.b]), caveats: ['Duplicate suggestions require corroborating dates, places or parents; identical names alone never qualify. Review each pair before merging.'],
  };
}

export function toolMissingBirth(ctx: ToolContext): ToolResult {
  const g = ctx.graph;
  const ids = [...g.persons.values()].filter((p) => !eventOf(p, 'BIRT')?.date).map((p) => p.id);
  return { tool: 'missing_birth', summary: `${ids.length} person(s) have no recorded birth date.`, facts: ids.slice(0, 200).map((id) => ({ statement: label(g, id), basis: 'missing', personIds: [id], sourceIds: [] })), personIds: ids, caveats: [] };
}

export function toolRelationship(ctx: ToolContext, a: ID, b: ID): ToolResult {
  const g = ctx.graph;
  const r = findRelationship(g, a, b);
  const facts: Fact[] = r.blood.map((bl) => ({
    statement: `${displayName(g.persons.get(b))} is ${displayName(g.persons.get(a))}'s ${bl.label} (${bl.generationsFromA} generation(s) up from A, ${bl.generationsFromB} from B; common ancestor(s): ${bl.commonAncestors.map((c) => label(g, c)).join(' & ')}). Route: ${bl.route.map((x) => displayName(g.persons.get(x))).join(' → ')}`,
    basis: 'inferred', personIds: bl.route, sourceIds: [],
  }));
  if (r.otherPath) facts.push({ statement: `Connection through recorded marriage/adoption/other links: ${displayName(g.persons.get(a))} ${r.otherPath.description}`, basis: 'inferred', personIds: [a, ...r.otherPath.steps.map((s) => s.to)], sourceIds: [] });
  return {
    tool: 'relationship', summary: r.found ? `Found ${r.blood.length} blood relationship(s)${r.otherPath ? ' and a non-blood connection' : ''} between ${label(g, a)} and ${label(g, b)}.` : `No recorded path connects ${label(g, a)} and ${label(g, b)}.`,
    facts, personIds: [a, b], caveats: ['Relationships are calculated from recorded links; they are only as reliable as the evidence on each link.', 'Blood relationships use biological (birth) links only; adoptive, step and marriage links are reported separately.'],
  };
}

export function toolEarliest(ctx: ToolContext): ToolResult {
  const g = ctx.graph;
  let best: { p: Person; y: number } | undefined;
  for (const p of g.persons.values()) {
    if (p.traditional) continue;
    const y = eventOf(p, 'BIRT')?.date?.sortYear ?? eventOf(p, 'CHR')?.date?.sortYear ?? eventOf(p, 'DEAT')?.date?.sortYear;
    if (y !== undefined && (!best || y < best.y)) best = { p, y };
  }
  if (!best) return { tool: 'earliest', summary: 'No person has a usable dated event.', facts: [], personIds: [], caveats: [] };
  const src = citedSources(best.p);
  return {
    tool: 'earliest', summary: `The earliest dated person is ${label(g, best.p.id)} (year ≈ ${best.y}).`,
    facts: [{ statement: `${label(g, best.p.id)}: earliest dated event ≈ ${best.y}`, basis: src.length ? 'documented' : 'inferred', personIds: [best.p.id], sourceIds: src }],
    personIds: [best.p.id], caveats: [src.length ? '' : 'This date has no source citation.', 'Profiles marked as traditional/legendary are excluded.'].filter(Boolean),
  };
}

export function toolWeakEvidence(ctx: ToolContext, scopeId?: ID): ToolResult {
  const g = ctx.graph;
  const scope = scopeId ? new Set([scopeId, ...g.ancestors(scopeId).keys()]) : new Set(g.persons.keys());
  const facts: Fact[] = [];
  for (const id of scope) for (const par of g.parents(id)) {
    if (!scope.has(par.personId)) continue;
    if (linkEvidence(g, id, par.familyId).length === 0) facts.push({ statement: `${label(g, id)} → parent ${label(g, par.personId)} has no cited source`, basis: 'missing', personIds: [id, par.personId], sourceIds: [] });
  }
  return { tool: 'weak_evidence', summary: `${facts.length} parent-child link(s) lack any source citation.`, facts: facts.slice(0, 200), personIds: [...new Set(facts.flatMap((f) => f.personIds))], caveats: ['A link counts as sourced when the child’s birth/baptism or the family’s events cite a source.'] };
}

export function toolResearchPlan(ctx: ToolContext, id: ID): ToolResult {
  const g = ctx.graph;
  const p = g.persons.get(id)!;
  const leads = researchLeads(g, id, 15).filter((l) => l.personId === id || g.parents(id).some((x) => x.personId === l.personId));
  const issues = checkConsistency(new FamilyGraph([p, ...g.parents(id).map((x) => g.persons.get(x.personId)!)], g.childFamilies(id))).filter((i) => i.personId === id && i.kind !== 'missing-birth');
  const birth = eventOf(p, 'BIRT');
  const facts: Fact[] = [
    ...leads.map((l) => ({ statement: `Task: ${l.task}`, basis: 'missing' as Basis, personIds: [l.personId], sourceIds: [] })),
    ...issues.map((i) => ({ statement: `Resolve conflict: ${i.message}`, basis: 'inferred' as Basis, personIds: [i.personId], sourceIds: [] })),
  ];
  if (birth?.place) facts.push({ statement: `Search civil/parish records for ${birth.place}${birth.date?.sortYear ? ` around ${birth.date.sortYear}` : ''}.`, basis: 'inferred', personIds: [id], sourceIds: [] });
  const surname = p.names[0]?.surname;
  if (surname) facts.push({ statement: `Check spelling variants of "${surname}" in indexes (Soundex-based).`, basis: 'inferred', personIds: [id], sourceIds: [] });
  return { tool: 'research_plan', summary: `Research plan for ${label(g, id)}: ${facts.length} step(s).`, facts, personIds: [id], caveats: ['OmniTree searches only your imported data; it does not access external record collections in V0.1.'] };
}

export function toolSourcesForRelationship(ctx: ToolContext, a: ID, b: ID): ToolResult {
  const g = ctx.graph;
  const facts: Fact[] = [];
  const check = (child: ID, parent: ID) => {
    for (const par of g.parents(child)) if (par.personId === parent) {
      const src = linkEvidence(g, child, par.familyId);
      facts.push({ statement: `${label(g, parent)} is recorded as ${par.relation} parent of ${label(g, child)}. Sources: ${src.length ? src.map((s) => ctx.sources.get(s)?.title ?? s).join('; ') : 'none cited'}`, basis: src.length ? 'documented' : 'missing', personIds: [child, parent], sourceIds: src });
    }
  };
  check(a, b); check(b, a);
  for (const pt of g.partners(a)) if (pt.personId === b) {
    const fam = g.families.get(pt.familyId)!;
    const src = [...new Set(fam.events.flatMap((e) => e.citations.map((c) => c.sourceId)))];
    facts.push({ statement: `Partners in family ${fam.gedcomId ?? fam.id}. Sources: ${src.length ? src.map((s) => ctx.sources.get(s)?.title ?? s).join('; ') : 'none cited'}`, basis: src.length ? 'documented' : 'missing', personIds: [a, b], sourceIds: src });
  }
  if (!facts.length) {
    // Fall back to evidence along the computed route.
    const rel = findRelationship(g, a, b).blood[0];
    if (rel) for (let i = 0; i + 1 < rel.route.length; i++) check(rel.route[i], rel.route[i + 1]), check(rel.route[i + 1], rel.route[i]);
  }
  return { tool: 'relationship_sources', summary: facts.length ? `Evidence for ${facts.length} link(s) between ${label(g, a)} and ${label(g, b)}.` : 'No direct or computed links found between these people.', facts, personIds: [a, b], caveats: [] };
}
