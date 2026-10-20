import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import { approximateLocation } from '../maps/gazetteer';
import { OmniDB, setDb, getDb } from '../database/db';
import { commitImport, createWorkspace, loadWorkspaceData, mergePersons, undoMerge } from '../database/repo';
import { parseGedcom } from '../genealogy/gedcom/parser';
import { FAMILY_GED } from './fixtures/synthetic';

let n = 0;
beforeEach(() => setDb(new OmniDB(`v02-${n++}`)));

describe('gazetteer', () => {
  it('picks the most specific known component', () => {
    expect(approximateLocation('Brooklyn, New York, USA')).toMatchObject({ level: 'city', matched: 'brooklyn' });
    expect(approximateLocation('New York, New York, USA')).toMatchObject({ matched: 'new york city' });
    expect(approximateLocation('Eastbrook, Yorkshire, England')).toMatchObject({ level: 'region', matched: 'yorkshire' });
    expect(approximateLocation('Atlantis')).toBeUndefined();
  });
});

describe('merge undo', () => {
  it('restores both people and family links exactly', async () => {
    const ws = await createWorkspace('U');
    const parsed = parseGedcom(FAMILY_GED, { workspaceId: ws.id, importId: 'imp1' });
    await commitImport(ws.id, 'imp1', 'a.ged', parsed);
    const before = await loadWorkspaceData(ws.id);
    const keep = parsed.persons.find((p) => p.gedcomId === '@I3@')!; // has families
    const drop = parsed.persons.find((p) => p.gedcomId === '@I16@')!;
    const id = await mergePersons(keep, drop);
    expect((await loadWorkspaceData(ws.id)).persons).toHaveLength(16);
    await undoMerge(id);
    const after = await loadWorkspaceData(ws.id);
    expect(after.persons).toHaveLength(17);
    expect(after.persons.find((p) => p.id === keep.id)!.names).toEqual(keep.names);
    expect(after.graph.children(keep.id).map((c) => c.personId).sort()).toEqual(before.graph.children(keep.id).map((c) => c.personId).sort());
    await expect(undoMerge(id)).rejects.toThrow(/already undone/);
    expect((await getDb().audit.toArray()).some((a) => a.action === 'undo-merge')).toBe(true);
  });
});

import { OmniAgent } from '../ai/agent/omniAgent';
import { checkGrounding, phraseAnswer, planIntent, type ChatEngine } from '../ai/models/llmPlanner';
import { loadFamily } from './helpers';

const mock = (reply: string): ChatEngine => ({ complete: async () => reply });

describe('local model adapter (mock engine)', () => {
  const { graph, parsed, byGed } = loadFamily();
  const agent = new OmniAgent({ graph, sources: parsed.sources, rootId: byGed('@I11@') });
  it('accepts only supported tool names from the planner', async () => {
    expect(await planIntent(mock('{"tool":"descendants"}'), 'who came after Aldric?')).toBe('descendants');
    expect(await planIntent(mock('{"tool":"invent_ancestors"}'), 'x')).toBeUndefined();
    expect(await planIntent(mock('I think they are cousins'), 'x')).toBeUndefined();
  });
  it('planner-selected intent runs the real tool', async () => {
    const a = await agent.ask('who came after Aldric Thornwood', { intentOverride: 'descendants' });
    expect(a.intent).toBe('descendants');
    expect(a.personIds).toContain(byGed('@I11@'));
  });
  it('rejects rephrasings that add people, years or cM figures', async () => {
    const a = await agent.ask('Show my parents and grandparents.');
    expect(checkGrounding('Arthur\'s father is Henry Thornwood and his mother June Vale.', a, graph).ok).toBe(true);
    expect(checkGrounding('Lena Reed is also a grandparent.', a, graph).ok).toBe(false);
    expect(checkGrounding('Henry was born in 1777.', a, graph).ok).toBe(false);
    expect(checkGrounding('They share 850 cM.', a, graph).ok).toBe(false);
    const p = await phraseAnswer(mock('Arthur has a grandmother named Ivy Brook.'), 'q', a, graph);
    expect(p.accepted).toBe(false);
  });
});
