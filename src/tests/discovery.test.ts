import { describe, expect, it } from 'vitest';
import { checkConsistency, findDuplicates, researchLeads, soundex } from '../genealogy/discovery/discovery';
import { loadFamily } from './helpers';
import { parseGedcom } from '../genealogy/gedcom/parser';
import { FamilyGraph } from '../genealogy/graph/familyGraph';

const { graph, byGed } = loadFamily();

describe('duplicate suggestion scoring', () => {
  it('suggests spelling variant with matching birth year and place', () => {
    const d = findDuplicates(graph);
    const pair = d.find((c) => [c.a, c.b].includes(byGed('@I1@')) && [c.a, c.b].includes(byGed('@I17@')));
    expect(pair).toBeDefined();
    expect(pair!.score).toBeGreaterThanOrEqual(50);
  });
  it('does not suggest same-name people with conflicting birthplaces as strong duplicates', () => {
    const d = findDuplicates(graph);
    // Two Henry Thornwoods born 1900: New York vs Boston, different parents → only weak evidence (same year) → may appear but never above parents-matched score
    const pair = d.find((c) => [c.a, c.b].includes(byGed('@I6@')) && [c.a, c.b].includes(byGed('@I16@')));
    if (pair) expect(pair.reasons).not.toContain('matching birth place');
  });
  it('identical names alone never qualify (false positive guard)', () => {
    const ged = '0 HEAD\n0 @I1@ INDI\n1 NAME John /Smith/\n0 @I2@ INDI\n1 NAME John /Smith/\n0 TRLR';
    const p = parseGedcom(ged, { workspaceId: 'w', importId: 'i' });
    expect(findDuplicates(new FamilyGraph(p.persons, p.families), 0)).toHaveLength(0);
  });
  it('rejects pairs with far-apart birth years or different sex', () => {
    const ged = '0 HEAD\n0 @I1@ INDI\n1 NAME Ann /Lee/\n1 SEX F\n1 BIRT\n2 DATE 1800\n0 @I2@ INDI\n1 NAME Ann /Lee/\n1 SEX F\n1 BIRT\n2 DATE 1850\n0 @I3@ INDI\n1 NAME Ann /Lee/\n1 SEX M\n1 BIRT\n2 DATE 1800\n0 TRLR';
    const p = parseGedcom(ged, { workspaceId: 'w', importId: 'i' });
    expect(findDuplicates(new FamilyGraph(p.persons, p.families), 0)).toHaveLength(0);
  });
  it('siblings in one family are never duplicates', () => {
    const ged = '0 HEAD\n0 @I1@ INDI\n1 NAME Tom /Ray/\n1 BIRT\n2 DATE 1900\n1 FAMC @F1@\n0 @I2@ INDI\n1 NAME Tom /Ray/\n1 BIRT\n2 DATE 1900\n1 FAMC @F1@\n0 @F1@ FAM\n1 CHIL @I1@\n1 CHIL @I2@\n0 TRLR';
    const p = parseGedcom(ged, { workspaceId: 'w', importId: 'i' });
    expect(findDuplicates(new FamilyGraph(p.persons, p.families), 0)).toHaveLength(0);
  });
  it('soundex groups variants', () => {
    expect(soundex('Robert')).toBe(soundex('Rupert'));
    expect(soundex('Thornwood')).toBe('T653');
  });
});

describe('consistency checks', () => {
  it('flags child born before parent and death before birth', () => {
    const ged = '0 HEAD\n0 @P@ INDI\n1 NAME P /X/\n1 SEX F\n1 BIRT\n2 DATE 1900\n1 DEAT\n2 DATE 1890\n1 FAMS @F@\n0 @C@ INDI\n1 NAME C /X/\n1 BIRT\n2 DATE 1895\n1 FAMC @F@\n0 @F@ FAM\n1 WIFE @P@\n1 CHIL @C@\n0 TRLR';
    const p = parseGedcom(ged, { workspaceId: 'w', importId: 'i' });
    const issues = checkConsistency(new FamilyGraph(p.persons, p.families));
    expect(issues.some((i) => i.kind === 'date-order')).toBe(true);
    expect(issues.some((i) => i.kind === 'parent-age' && i.severity === 'error')).toBe(true);
  });
  it('generates research leads for gaps', () => {
    const leads = researchLeads(graph, byGed('@I11@'));
    expect(leads.some((l) => /parents of/.test(l.task))).toBe(true);
  });
});
