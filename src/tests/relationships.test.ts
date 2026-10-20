import { describe, expect, it } from 'vitest';
import { findRelationship, relationshipLabel } from '../genealogy/relationships/pathfinder';
import { loadFamily } from './helpers';
import { parseGedcom } from '../genealogy/gedcom/parser';
import { FamilyGraph } from '../genealogy/graph/familyGraph';

const { graph, byGed } = loadFamily();
const rel = (a: string, b: string) => findRelationship(graph, byGed(a), byGed(b));

describe('relationship labels', () => {
  it('names cousins and removals', () => {
    expect(relationshipLabel(2, 2)).toBe('first cousin');
    expect(relationshipLabel(3, 3)).toBe('second cousin');
    expect(relationshipLabel(4, 4)).toBe('third cousin');
    expect(relationshipLabel(2, 3)).toBe('first cousin once removed');
    expect(relationshipLabel(2, 4)).toBe('first cousin twice removed');
    expect(relationshipLabel(0, 3, 'M')).toBe('great-grandson');
    expect(relationshipLabel(4, 0, 'F')).toBe('2× great-grandmother');
    expect(relationshipLabel(2, 1, 'F')).toBe('aunt');
    expect(relationshipLabel(1, 2, 'M')).toBe('nephew');
    expect(relationshipLabel(3, 1, 'M')).toBe('grand-uncle');
  });
});

describe('PathFinder', () => {
  it('parent / grandparent / great-grandparent', () => {
    expect(rel('@I6@', '@I3@').blood[0].label).toBe('father');
    expect(rel('@I11@', '@I1@').blood[0].label).toBe('great-grandfather');
    expect(rel('@I1@', '@I11@').blood[0].label).toBe('great-grandson');
  });
  it('full siblings and half siblings', () => {
    const s = rel('@I3@', '@I4@');
    expect(s.blood).toHaveLength(1);
    expect(s.blood[0].label).toBe('sister');
    expect(s.blood[0].commonAncestors).toHaveLength(2);
    const h = rel('@I6@', '@I15@');
    expect(h.blood[0].label).toBe('half-brother');
  });
  it('first cousins and once removed with full route', () => {
    const c = rel('@I6@', '@I8@');
    expect(c.blood[0].label).toBe('first cousin');
    const r = rel('@I11@', '@I8@');
    expect(r.blood[0].label).toBe('first cousin once removed');
    expect(r.blood[0].route.map((id) => graph.persons.get(id)!.gedcomId)[0]).toBe('@I11@');
    expect(r.blood[0].route.map((id) => graph.persons.get(id)!.gedcomId).at(-1)).toBe('@I8@');
    expect(rel('@I11@', '@I13@').blood[0].label).toBe('second cousin');
  });
  it('aunt/uncle and niece/nephew', () => {
    expect(rel('@I6@', '@I4@').blood[0].label).toBe('aunt');
    expect(rel('@I4@', '@I6@').blood[0].label).toBe('nephew');
  });
  it('does not treat adoption as blood but reports the adoptive path', () => {
    const r = rel('@I8@', '@I9@');
    expect(r.blood).toHaveLength(0);
    expect(r.otherPath!.steps.some((s) => s.kind === 'adoptive-child')).toBe(true);
    expect(r.found).toBe(true);
  });
  it('marriage/affinity paths are not blood', () => {
    const r = rel('@I3@', '@I5@');
    expect(r.blood).toHaveLength(0);
    expect(r.otherPath!.steps[0].kind).toBe('partner');
    const inlaw = rel('@I5@', '@I4@');
    expect(inlaw.blood).toHaveLength(0);
    expect(inlaw.otherPath).toBeDefined();
  });
  it('reports no path for unconnected people', () => {
    const r = rel('@I6@', '@I16@');
    expect(r.found).toBe(false);
    expect(r.blood).toHaveLength(0);
  });
  it('finds multiple common ancestors (double cousins / pedigree collapse)', () => {
    // Two brothers marry two sisters → children are double first cousins via two couples.
    const ged = `0 HEAD
0 @A@ INDI
1 SEX M
0 @B@ INDI
1 SEX F
0 @C@ INDI
1 SEX M
0 @D@ INDI
1 SEX F
0 @B1@ INDI
1 SEX M
0 @B2@ INDI
1 SEX M
0 @S1@ INDI
1 SEX F
0 @S2@ INDI
1 SEX F
0 @K1@ INDI
1 NAME K /One/
0 @K2@ INDI
1 NAME K /Two/
0 @F1@ FAM
1 HUSB @A@
1 WIFE @B@
1 CHIL @B1@
1 CHIL @B2@
0 @F2@ FAM
1 HUSB @C@
1 WIFE @D@
1 CHIL @S1@
1 CHIL @S2@
0 @F3@ FAM
1 HUSB @B1@
1 WIFE @S1@
1 CHIL @K1@
0 @F4@ FAM
1 HUSB @B2@
1 WIFE @S2@
1 CHIL @K2@
0 TRLR`;
    const p = parseGedcom(ged, { workspaceId: 'w', importId: 'i' });
    const g = new FamilyGraph(p.persons, p.families);
    const id = (x: string) => p.persons.find((q) => q.gedcomId === x)!.id;
    const r = findRelationship(g, id('@K1@'), id('@K2@'));
    expect(r.blood).toHaveLength(2);
    expect(r.blood.every((b) => b.label === 'first cousin')).toBe(true);
  });
});

describe('graph integrity', () => {
  it('computes ancestors, descendants, maternal line, siblings', () => {
    expect(graph.ancestors(byGed('@I11@')).size).toBe(6);
    expect([...graph.ancestors(byGed('@I13@'), { line: 'maternal' }).keys()].map((x) => graph.persons.get(x)!.gedcomId)).toContain('@I4@');
    expect(graph.ancestors(byGed('@I13@'), { line: 'maternal' }).has(byGed('@I12@'))).toBe(false);
    expect(graph.descendants(byGed('@I1@')).size).toBe(8);
    const sib = graph.siblings(byGed('@I8@'));
    expect(sib.find((s) => s.personId === byGed('@I9@'))!.kind).toBe('step-or-adoptive');
    expect(graph.findAncestryCycles()).toHaveLength(0);
    expect(graph.maxGenerations()).toBe(4);
  });
});
