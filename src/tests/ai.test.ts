import { describe, expect, it } from 'vitest';
import { OmniAgent } from '../ai/agent/omniAgent';
import { loadFamily } from './helpers';
import { parseGenotypeText, deserializeVariants, serializeVariants } from '../dna/parsers/genotype';
import { syntheticPanel, to23andMeFormat, toAncestryFormat } from './fixtures/synthetic';
import type { DnaKit } from '../database/types';

const { graph, parsed, byGed } = loadFamily();
const agent = (extra: Partial<ConstructorParameters<typeof OmniAgent>[0]> = {}) => new OmniAgent({ graph, sources: parsed.sources, rootId: byGed('@I11@'), ...extra });

describe('OmniAI tool grounding', () => {
  it('parents and grandparents come from the database with IDs', async () => {
    const a = await agent().ask('Show my parents and grandparents.');
    expect(a.intent).toBe('parents');
    expect(a.personIds).toEqual(expect.arrayContaining([byGed('@I6@'), byGed('@I10@'), byGed('@I3@'), byGed('@I5@')]));
    expect(a.personIds).toHaveLength(4);
    for (const id of a.personIds) expect(graph.persons.has(id)).toBe(true);
  });
  it('relationship answer for two named people', async () => {
    const a = await agent().ask('Show how Arthur Thornwood and Ivy Brook are related');
    expect(a.text).toMatch(/first cousin once removed/);
  });
  it('asks for clarification on ambiguous names instead of guessing', async () => {
    const a = await agent().ask('Find all known ancestors of Henry Thornwood');
    expect(a.needsClarification!.candidates).toHaveLength(2);
  });
  it('place search cites sources and marks documented facts', async () => {
    const a = await agent().ask('Which ancestors lived in New York?');
    expect(a.personIds).toContain(byGed('@I3@'));
    expect(a.sourceIds.length).toBeGreaterThan(0);
    expect(a.text).toContain('documented');
  });
  it('earliest person, duplicates, missing births, weak evidence', async () => {
    expect((await agent().ask('Find the earliest documented person in my tree.')).personIds[0]).toBeDefined();
    expect((await agent().ask('Find possible duplicates.')).text).toMatch(/None are merged automatically/);
    expect((await agent().ask('Find records with missing birth dates.')).personIds).toContain(byGed('@I5@'));
    expect((await agent().ask('Which ancestor connections have weak evidence?')).text).toMatch(/lack any source/);
  });
  it('maternal line excludes paternal ancestors', async () => {
    const a = await agent({ rootId: byGed('@I13@') }).ask('Show my maternal family line.');
    expect(a.personIds).toContain(byGed('@I8@'));
    expect(a.personIds).not.toContain(byGed('@I12@'));
  });
  it('unknown request does not fabricate an answer', async () => {
    const a = await agent().ask('What is the weather on Mars?');
    expect(a.intent).toBe('search');
    expect(a.results).toHaveLength(0);
  });
  it('DNA comparison runs the real comparison', async () => {
    const owner = byGed('@I11@');
    const mk = (id: string, provider: DnaKit['provider'], text: string): DnaKit => {
      const k = parseGenotypeText(text);
      return { id, workspaceId: 'ws1', personId: owner, provider, fileName: id, build: k.build, variantCount: k.variants.length, noCallCount: 0, invalidRows: 0, duplicateCount: 0, chromosomeCounts: {}, importedAt: 0, encrypted: false, payload: serializeVariants(k.variants) };
    };
    const panel = syntheticPanel(3000, 5);
    const kits = [mk('anc', 'ancestrydna', toAncestryFormat(panel)), mk('tw', '23andme', to23andMeFormat(panel))];
    const a = await agent({ kits, loadVariants: async (k) => deserializeVariants(k.payload as string) }).ask('Compare my AncestryDNA and 23andMe files.');
    expect(a.dna!.concordanceRate).toBe(1);
    expect(a.text).toMatch(/does not produce a complete or clinically accurate genome/);
    const s = await agent({ kits }).ask('Summarize what my uploaded DNA can establish.');
    expect(s.text).toMatch(/CANNOT/);
  });
});
