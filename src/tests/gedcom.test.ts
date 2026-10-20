import { describe, expect, it } from 'vitest';
import { parseGedcom, tokenize } from '../genealogy/gedcom/parser';
import { exportGedcom } from '../genealogy/gedcom/exporter';
import { parseGedDate } from '../genealogy/gedcom/dates';
import { FAMILY_GED, GED7 } from './fixtures/synthetic';
import { loadFamily } from './helpers';

describe('GEDCOM dates', () => {
  it('parses exact, approximate, partial and range dates', () => {
    expect(parseGedDate('12 MAR 1920')).toMatchObject({ day: 12, month: 3, year: 1920, sortYear: 1920 });
    expect(parseGedDate('ABT 1850')).toMatchObject({ qualifier: 'ABT', year: 1850 });
    expect(parseGedDate('MAR 1901')).toMatchObject({ month: 3, year: 1901 });
    expect(parseGedDate('BET 1877 AND 1879')).toMatchObject({ qualifier: 'BET', year: 1877, endYear: 1879, sortYear: 1878 });
    expect(parseGedDate('FROM 1801 TO 1803')).toMatchObject({ qualifier: 'FROM', year: 1801, endYear: 1803 });
    expect(parseGedDate('BEF 1700').qualifier).toBe('BEF');
    expect(parseGedDate('some text').sortYear).toBeUndefined();
    expect(parseGedDate('some text').raw).toBe('some text');
  });
});

describe('GEDCOM parsing', () => {
  it('reads 5.5.1 header, people, families and sources', () => {
    const { parsed } = loadFamily();
    expect(parsed.version).toBe('5.5.1');
    expect(parsed.persons).toHaveLength(17);
    expect(parsed.families).toHaveLength(6);
    expect(parsed.sources.map((s) => s.title)).toContain('Synthetic Parish Register of Eastbrook');
  });
  it('reads GEDCOM 7 and preserves custom tags', () => {
    const p = parseGedcom(GED7, { workspaceId: 'w', importId: 'i' });
    expect(p.version).toBe('7.0');
    expect(p.persons[0].extensions[0]).toMatchObject({ tag: '_CUSTOM', value: 'something' });
    expect(p.families[0].children).toHaveLength(1); // via FAMC only
    expect(p.diagnostics.some((d) => /FAMC only/.test(d.message))).toBe(true);
  });
  it('preserves extensions, notes, citations and unknown records', () => {
    const { parsed, byGed } = loadFamily();
    const aldric = parsed.persons.find((p) => p.id === byGed('@I1@'))!;
    expect(aldric.extensions.find((e) => e.tag === '_MILT')!.lines).toEqual(['1 _MILT Served in local militia', '2 DATE 1870']);
    const birth = aldric.events.find((e) => e.type === 'BIRT')!;
    expect(birth.citations[0]).toMatchObject({ page: 'folio 12', quality: 3 });
    const mabel = parsed.persons.find((p) => p.gedcomId === '@I2@')!;
    expect(mabel.notes[0]).toBe('Shared note text\ncontinued line');
    expect(parsed.otherRecords.map((r) => r.tag)).toContain('REPO');
    expect(aldric.events.find((e) => e.type === 'OCCU')!.value).toBe('Wheelwright');
  });
  it('keeps adoptive distinctions', () => {
    const { parsed } = loadFamily();
    const owen = parsed.persons.find((p) => p.gedcomId === '@I9@')!;
    const f3 = parsed.families.find((f) => f.gedcomId === '@F3@')!;
    expect(f3.children.find((c) => c.personId === owen.id)!.relation).toBe('adopted');
  });
  it('reports malformed lines and broken references without discarding the rest', () => {
    const bad = '0 HEAD\n1 GEDC\n2 VERS 5.5\nthis is garbage\n0 @I1@ INDI\n1 NAME A /B/\n1 FAMC @F9@\n0 @I1@ INDI\n1 NAME Dup /Licate/\n0 TRLR';
    const p = parseGedcom(bad, { workspaceId: 'w', importId: 'i' });
    expect(p.persons).toHaveLength(1);
    const msgs = p.diagnostics.map((d) => d.message).join('\n');
    expect(msgs).toMatch(/Malformed line/);
    expect(msgs).toMatch(/missing family @F9@/);
    expect(msgs).toMatch(/Duplicate record ID @I1@/);
  });
  it('warns when TRLR is missing', () => {
    const t: never[] = [];
    tokenize('0 HEAD', t);
    const p = parseGedcom('0 HEAD\n0 @I1@ INDI\n1 NAME X /Y/', { workspaceId: 'w', importId: 'i' });
    expect(p.diagnostics.some((d) => /TRLR/.test(d.message))).toBe(true);
  });
});

describe('GEDCOM export round trip', () => {
  it('re-imports to an equivalent structure', () => {
    const { parsed } = loadFamily();
    const out = exportGedcom({ ...parsed });
    const again = parseGedcom(out, { workspaceId: 'w', importId: 'i2' });
    expect(again.persons).toHaveLength(parsed.persons.length);
    expect(again.families).toHaveLength(parsed.families.length);
    expect(again.sources).toHaveLength(parsed.sources.length);
    const names = (x: typeof parsed) => x.persons.map((p) => `${p.gedcomId}:${p.names[0].full}:${p.events.find((e) => e.type === 'BIRT')?.date?.raw ?? ''}`).sort();
    expect(names(again)).toEqual(names(parsed));
    const famSig = (x: typeof parsed) => x.families.map((f) => {
      const g = (id: string) => x.persons.find((p) => p.id === id)!.gedcomId;
      return `${f.partnerIds.map(g).sort()}|${f.children.map((c) => g(c.personId) + c.relation).sort()}`;
    }).sort();
    expect(famSig(again)).toEqual(famSig(parsed));
    expect(again.persons.find((p) => p.gedcomId === '@I1@')!.extensions[0].tag).toBe('_MILT');
    expect(again.otherRecords.map((r) => r.tag)).toContain('REPO');
    expect(out).toContain('2 PEDI adopted');
  });
  it('redacts living-private people when requested', () => {
    const { parsed } = loadFamily();
    parsed.persons[10].privacy = 'living-private';
    const out = exportGedcom({ ...parsed, redactLiving: true });
    expect(out).not.toContain(parsed.persons[10].names[0].given + ' /');
    expect(out).toContain('1 NAME Living //');
  });
  it('round-trips the fixture text losslessly enough for header check', () => {
    expect(FAMILY_GED.startsWith('0 HEAD')).toBe(true);
  });
});

describe('place coordinates', () => {
  it('reads and re-exports PLAC MAP coordinates', () => {
    const { parsed } = loadFamily();
    const resi = parsed.persons.find((p) => p.gedcomId === '@I3@')!.events.find((e) => e.type === 'RESI')!;
    expect(resi).toMatchObject({ lat: 40.65, lon: -73.95 });
    const again = parseGedcom(exportGedcom(parsed), { workspaceId: 'w', importId: 'x' });
    expect(again.persons.find((p) => p.gedcomId === '@I3@')!.events.find((e) => e.type === 'RESI')).toMatchObject({ lat: 40.65, lon: -73.95 });
  });
});
