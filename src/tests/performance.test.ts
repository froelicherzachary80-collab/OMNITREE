import { describe, expect, it } from 'vitest';
import { parseGedcom } from '../genealogy/gedcom/parser';
import { FamilyGraph } from '../genealogy/graph/familyGraph';
import { findRelationship } from '../genealogy/relationships/pathfinder';
import { findDuplicates, checkConsistency } from '../genealogy/discovery/discovery';
import { exportGedcom } from '../genealogy/gedcom/exporter';
import { syntheticLargeGedcom } from './fixtures/synthetic';

describe('15,000-person synthetic dataset', () => {
  it('parses, indexes, queries and exports within budget', () => {
    const text = syntheticLargeGedcom(15000);
    let t = performance.now();
    const p = parseGedcom(text, { workspaceId: 'w', importId: 'i' });
    const parseMs = performance.now() - t;
    expect(p.persons.length).toBeGreaterThanOrEqual(15000);
    t = performance.now();
    const g = new FamilyGraph(p.persons, p.families);
    const last = p.persons[p.persons.length - 1].id;
    const anc = g.ancestors(last);
    const rel = findRelationship(g, last, p.persons[p.persons.length - 50].id);
    const queryMs = performance.now() - t;
    t = performance.now();
    findDuplicates(g);
    checkConsistency(g);
    const out = exportGedcom({ persons: p.persons, families: p.families, sources: [] });
    const restMs = performance.now() - t;
    console.log(`15k: parse ${parseMs.toFixed(0)}ms, graph+queries ${queryMs.toFixed(0)}ms, discovery+export ${restMs.toFixed(0)}ms, ancestors=${anc.size}, related=${rel.found}`);
    expect(anc.size).toBeGreaterThan(0);
    expect(out.length).toBeGreaterThan(100000);
    expect(parseMs).toBeLessThan(10000);
    expect(queryMs).toBeLessThan(3000);
  });
});
