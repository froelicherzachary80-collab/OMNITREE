import type { DnaKit, ID, Source } from '../../database/types';
import { displayName } from '../../database/types';
import type { FamilyGraph } from '../../genealogy/graph/familyGraph';
import { NameIndex } from '../retrieval/nameIndex';
import * as T from '../tools/genealogyTools';
import type { ToolResult } from '../tools/genealogyTools';
import { compareKits, type KitComparison } from '../../dna/comparisons/compare';
import type { VariantCall } from '../../database/types';

export interface AgentContext {
  graph: FamilyGraph;
  sources: Source[];
  rootId?: ID;
  selectedId?: ID;
  kits?: DnaKit[];
  loadVariants?: (kit: DnaKit) => Promise<VariantCall[]>;
}

export interface AgentAnswer {
  intent: string;
  text: string;
  results: ToolResult[];
  personIds: ID[];
  sourceIds: ID[];
  needsClarification?: { mention: string; candidates: ID[] };
  dna?: KitComparison;
}

interface Intent { name: string; test: RegExp; needs: 0 | 1 | 2 }
const INTENTS: Intent[] = [
  { name: 'relationship_sources', test: /\b(sources?|evidence|citations?)\b.*\b(relationship|link|connection|between)\b/i, needs: 2 },
  { name: 'relationship', test: /\b(how|are)\b.*\b(related|connected)\b|\brelationship between\b/i, needs: 2 },
  { name: 'compare_dna', test: /\bcompare\b.*\b(dna|kits?|ancestry|23andme)\b/i, needs: 0 },
  { name: 'dna_summary', test: /\b(dna|genotype|kits?)\b.*\b(establish|summar|tell|show)|\bsummar\w*\b.*\bdna\b/i, needs: 0 },
  { name: 'research_plan', test: /\bresearch plan\b|\bplan\b.*\bresearch\b/i, needs: 1 },
  { name: 'duplicates', test: /\bduplicates?\b/i, needs: 0 },
  { name: 'missing_birth', test: /\bmissing\b.*\bbirth\b|\bno birth\b/i, needs: 0 },
  { name: 'weak_evidence', test: /\bweak\b.*\bevidence\b|\bunsourced\b|\bwithout sources\b/i, needs: 0 },
  { name: 'earliest', test: /\b(earliest|oldest)\b/i, needs: 0 },
  { name: 'place', test: /\b(lived|born|died|living|resided)\b.*\bin\b\s+([A-Z][\w .'-]+)/i, needs: 0 },
  { name: 'maternal', test: /\bmaternal\b/i, needs: 1 },
  { name: 'paternal', test: /\bpaternal\b/i, needs: 1 },
  { name: 'descendants', test: /\bdescendants?\b/i, needs: 1 },
  { name: 'parents', test: /\bparents?\b|\bgrandparents?\b/i, needs: 1 },
  { name: 'ancestors', test: /\bancestors?\b|\bancestry\b|\bforebears\b/i, needs: 1 },
];

export const SUGGESTED_QUESTIONS = [
  'Show my parents and grandparents.', 'Find all known ancestors of this person.', 'Show my maternal family line.',
  'Find descendants of this ancestor.', 'Which ancestors lived in New York?', 'Find possible duplicates.',
  'Find records with missing birth dates.', 'Show how these two people are related.', 'Find the earliest documented person in my tree.',
  'Which ancestor connections have weak evidence?', 'Compare my AncestryDNA and 23andMe files.', 'Summarize what my uploaded DNA can establish.',
  'Build a research plan for this ancestor.', 'Show the sources supporting this relationship.',
];

/**
 * OmniAI orchestrator. Every answer is produced by deterministic tools over the
 * actual database; nothing is generated without a tool result behind it.
 */
export class OmniAgent {
  private index: NameIndex;
  constructor(private ctx: AgentContext) { this.index = new NameIndex(ctx.graph.persons); }

  private resolvePeople(q: string): { ids: ID[]; ambiguous?: { mention: string; candidates: ID[] } } {
    const ids: ID[] = [];
    for (const m of this.index.findMentions(q)) {
      if (m.ids.length > 1) return { ids, ambiguous: { mention: m.text, candidates: m.ids } };
      ids.push(m.ids[0]);
    }
    const self = /\b(my|me|i)\b/i.test(q) && this.ctx.rootId;
    const thisPerson = /\b(this|selected)\s+(person|ancestor|profile)\b/i.test(q) && this.ctx.selectedId;
    if (ids.length === 0 && thisPerson) ids.push(this.ctx.selectedId!);
    if (self && !ids.includes(this.ctx.rootId!)) (ids.length < 2 ? ids.unshift(this.ctx.rootId!) : null);
    if (ids.length === 0 && this.ctx.selectedId) ids.push(this.ctx.selectedId);
    if (/\b(these|two) people\b/i.test(q) && ids.length < 2 && this.ctx.rootId && this.ctx.selectedId && this.ctx.rootId !== this.ctx.selectedId) return { ids: [this.ctx.rootId, this.ctx.selectedId] };
    return { ids };
  }

  detectIntent(q: string): Intent | undefined { return INTENTS.find((i) => i.test.test(q)); }

  /** Names of supported intents, for planners that choose a tool. */
  static intentNames() { return INTENTS.map((i) => i.name); }

  async ask(q: string, opts: { intentOverride?: string } = {}): Promise<AgentAnswer> {
    const intent = (opts.intentOverride && INTENTS.find((i) => i.name === opts.intentOverride)) || this.detectIntent(q);
    const tc: T.ToolContext = { graph: this.ctx.graph, sources: new Map(this.ctx.sources.map((s) => [s.id, s])) };
    if (!intent) {
      const hits = this.index.search(q, 8);
      return {
        intent: 'search', personIds: hits, sourceIds: [], results: [],
        text: hits.length
          ? `I didn't recognise a research command, but these profiles match your words:\n${hits.map((h) => '• ' + this.index.summarize(h)).join('\n')}`
          : `I couldn't match that to a supported research command or any person in your tree. Try one of the suggested questions.`,
      };
    }
    const people = this.resolvePeople(q);
    if (people.ambiguous) {
      return { intent: intent.name, text: `"${people.ambiguous.mention}" matches ${people.ambiguous.candidates.length} different people. Please select which one you mean — OmniTree never assumes people with the same name are the same individual.`, results: [], personIds: people.ambiguous.candidates, sourceIds: [], needsClarification: people.ambiguous };
    }
    if (people.ids.length < intent.needs) {
      return { intent: intent.name, text: intent.needs === 2 ? 'Please name two people (or set a home person and select another person in the tree).' : 'Please name a person, select one in the tree, or set your home person in Settings.', results: [], personIds: [], sourceIds: [] };
    }
    const [a, b] = people.ids;
    let r: ToolResult;
    let dna: KitComparison | undefined;
    switch (intent.name) {
      case 'parents': r = T.toolParentsGrandparents(tc, a); break;
      case 'ancestors': r = T.toolAncestors(tc, a); break;
      case 'maternal': r = T.toolAncestors(tc, a, 'maternal'); break;
      case 'paternal': r = T.toolAncestors(tc, a, 'paternal'); break;
      case 'descendants': r = T.toolDescendants(tc, a); break;
      case 'place': {
        const m = q.match(/\bin\s+([A-Z][\w .'-]+?)[?.!]*$/) ?? q.match(/\bin\s+([\w .'-]+?)[?.!]*$/i);
        const scoped = /\bancestors?\b/i.test(q) && (this.ctx.rootId ?? a);
        r = T.toolPlaceSearch(tc, (m?.[1] ?? '').trim(), scoped || undefined);
        break;
      }
      case 'duplicates': r = T.toolDuplicates(tc); break;
      case 'missing_birth': r = T.toolMissingBirth(tc); break;
      case 'relationship': r = T.toolRelationship(tc, a, b); break;
      case 'earliest': r = T.toolEarliest(tc); break;
      case 'weak_evidence': r = T.toolWeakEvidence(tc, /\bancestor/i.test(q) ? this.ctx.rootId : undefined); break;
      case 'research_plan': r = T.toolResearchPlan(tc, a); break;
      case 'relationship_sources': r = T.toolSourcesForRelationship(tc, a, b); break;
      case 'compare_dna': ({ r, dna } = await this.compareDna(a)); break;
      case 'dna_summary': r = this.dnaSummary(a); break;
      default: throw new Error('unhandled intent');
    }
    return this.compose(intent.name, [r], dna);
  }

  private ownerKits(personId?: ID) {
    const kits = this.ctx.kits ?? [];
    const own = personId ? kits.filter((k) => k.personId === personId) : [];
    return own.length ? own : kits;
  }

  private async compareDna(personId?: ID): Promise<{ r: ToolResult; dna?: KitComparison }> {
    const kits = this.ownerKits(personId);
    const anc = kits.find((k) => k.provider === 'ancestrydna');
    const tw = kits.find((k) => k.provider === '23andme' && k.personId === (anc?.personId ?? k.personId));
    if (!anc || !tw || !this.ctx.loadVariants) {
      return { r: { tool: 'compare_dna', summary: 'A comparison needs one AncestryDNA kit and one 23andMe kit linked to the same person.', facts: [], personIds: [], caveats: [`Kits available: ${kits.map((k) => `${k.provider} (${displayName(this.ctx.graph.persons.get(k.personId))})`).join(', ') || 'none'}.`] } };
    }
    const dna = compareKits({ label: anc.fileName, build: anc.build, variants: await this.ctx.loadVariants(anc) }, { label: tw.fileName, build: tw.build, variants: await this.ctx.loadVariants(tw) });
    return {
      dna,
      r: { tool: 'compare_dna', summary: `Compared ${anc.fileName} with ${tw.fileName}.`, facts: dna.interpretation.map((s) => ({ statement: s, basis: 'inferred', personIds: [anc.personId], sourceIds: [] })), personIds: [anc.personId], caveats: [dna.buildNote] },
    };
  }

  private dnaSummary(personId?: ID): ToolResult {
    const kits = this.ownerKits(personId);
    if (!kits.length) return { tool: 'dna_summary', summary: 'No DNA kits have been uploaded.', facts: [], personIds: [], caveats: [] };
    return {
      tool: 'dna_summary', summary: `${kits.length} DNA kit(s) on file.`,
      facts: [
        ...kits.map((k) => ({ statement: `${k.provider} kit "${k.fileName}" for ${displayName(this.ctx.graph.persons.get(k.personId))}: ${k.variantCount.toLocaleString()} variants, ${k.noCallCount.toLocaleString()} no-calls, build ${k.build ?? 'not stated in file'}.`, basis: 'documented' as const, personIds: [k.personId], sourceIds: [] })),
        { statement: 'Raw genotype files CAN establish: which SNP calls a file contains, data quality, and whether two files are consistent with coming from the same person.', basis: 'inferred', personIds: [], sourceIds: [] },
        { statement: 'They CANNOT by themselves establish: named relatives, shared centimorgans, ethnicity percentages, or medical conclusions. OmniTree does not compute IBD segments in this version.', basis: 'inferred', personIds: [], sourceIds: [] },
      ],
      personIds: kits.map((k) => k.personId), caveats: [],
    };
  }

  private compose(intent: string, results: ToolResult[], dna?: KitComparison): AgentAnswer {
    const lines: string[] = [];
    for (const r of results) {
      lines.push(r.summary);
      for (const f of r.facts.slice(0, 40)) {
        const tag = f.basis === 'documented' ? '📄 documented' : f.basis === 'inferred' ? '🔗 inferred' : '⚠ missing evidence';
        lines.push(`• ${f.statement}  [${tag}${f.sourceIds.length ? `; sources: ${f.sourceIds.map((s) => this.ctx.sources.find((x) => x.id === s)?.title ?? s).join('; ')}` : ''}]`);
      }
      if (r.facts.length > 40) lines.push(`…and ${r.facts.length - 40} more.`);
      for (const c of r.caveats) lines.push(`Note: ${c}`);
    }
    return {
      intent, text: lines.join('\n'), results, dna,
      personIds: [...new Set(results.flatMap((r) => r.personIds))],
      sourceIds: [...new Set(results.flatMap((r) => r.facts.flatMap((f) => f.sourceIds)))],
    };
  }
}
