import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import { OmniDB, setDb, getDb } from '../database/db';
import { addDnaKit, commitImport, createWorkspace, deleteWorkspace, exportWorkspaceJson, importWorkspaceJson, loadWorkspaceData, readKitVariants, rollbackImport } from '../database/repo';
import { parseGedcom } from '../genealogy/gedcom/parser';
import { FAMILY_GED, GED7, syntheticPanel, toAncestryFormat } from './fixtures/synthetic';
import { parseGenotypeText } from '../dna/parsers/genotype';
import { deriveKey, openWithPassphrase, randomBytes, sealWithPassphrase } from '../security/crypto';
import { NameIndex } from '../ai/retrieval/nameIndex';

let n = 0;
beforeEach(() => setDb(new OmniDB(`test-${n++}`)));

describe('import commit and rollback', () => {
  it('imports multiple files into one workspace and rolls one back', async () => {
    const ws = await createWorkspace('Test');
    await commitImport(ws.id, 'imp1', 'a.ged', parseGedcom(FAMILY_GED, { workspaceId: ws.id, importId: 'imp1' }));
    await commitImport(ws.id, 'imp2', 'b.ged', parseGedcom(GED7, { workspaceId: ws.id, importId: 'imp2' }));
    expect((await loadWorkspaceData(ws.id)).persons).toHaveLength(19);
    await rollbackImport('imp2');
    const d = await loadWorkspaceData(ws.id);
    expect(d.persons).toHaveLength(17);
    expect(d.imports.find((i) => i.id === 'imp2')!.status).toBe('rolled-back');
    expect((await getDb().audit.toArray()).map((a) => a.action)).toContain('rollback');
  });
  it('a failed commit leaves no partial data (transaction)', async () => {
    const ws = await createWorkspace('Test');
    const parsed = parseGedcom(FAMILY_GED, { workspaceId: ws.id, importId: 'imp1' });
    parsed.families.push({ ...parsed.families[0] }); // duplicate primary key → bulkAdd fails
    await expect(commitImport(ws.id, 'imp1', 'a.ged', parsed)).rejects.toThrow();
    expect(await getDb().persons.count()).toBe(0);
  });
});

describe('DNA storage and privacy', () => {
  it('requires an owner, encrypts genotypes, and keeps DNA out of the audit log', async () => {
    const ws = await createWorkspace('Test');
    const parsed = parseGedcom(FAMILY_GED, { workspaceId: ws.id, importId: 'imp1' });
    await commitImport(ws.id, 'imp1', 'a.ged', parsed);
    const kit = parseGenotypeText(toAncestryFormat(syntheticPanel(200)));
    await expect(addDnaKit(ws.id, 'nobody', 'x.txt', kit)).rejects.toThrow(/existing person/);
    const key = await deriveKey('correct horse', randomBytes(16), 1000);
    const owner = parsed.persons[0].id;
    const rec = await addDnaKit(ws.id, owner, 'x.txt', kit, key);
    const kit2 = await addDnaKit(ws.id, owner, 'y.txt', { ...kit, provider: '23andme' }, key);
    const p = await getDb().persons.get(owner);
    expect(p!.dnaKitIds).toEqual([rec.id, kit2.id]); // one person, two kits
    expect(rec.encrypted).toBe(true);
    expect(typeof rec.payload).not.toBe('string');
    const variants = await readKitVariants((await getDb().dnaKits.get(rec.id))!, key);
    expect(variants).toHaveLength(200);
    await expect(readKitVariants(rec)).rejects.toThrow(/Unlock/);
    const wrong = await deriveKey('wrong', randomBytes(16), 1000);
    await expect(readKitVariants(rec, wrong)).rejects.toThrow();
    const auditText = JSON.stringify(await getDb().audit.toArray());
    expect(auditText).not.toContain(kit.variants[0].rsid);
    await expect(rollbackImport('imp1')).rejects.toThrow(/DNA kit/);
  });
  it('AI retrieval summaries never include DNA and withhold living people', async () => {
    const parsed = parseGedcom(FAMILY_GED, { workspaceId: 'w', importId: 'i' });
    parsed.persons[0].privacy = 'living-private';
    parsed.persons[0].dnaKitIds = ['kit_1'];
    const idx = new NameIndex(new Map(parsed.persons.map((p) => [p.id, p])));
    const s = idx.summarize(parsed.persons[0].id);
    expect(s).toContain('Living person');
    expect(s).not.toContain('Aldric');
    expect(s).not.toContain('kit_1');
  });
});

describe('backup and restore', () => {
  it('encrypted backup round-trips; wrong passphrase fails; delete removes data', async () => {
    const ws = await createWorkspace('Backup');
    const parsed = parseGedcom(FAMILY_GED, { workspaceId: ws.id, importId: 'imp1' });
    await commitImport(ws.id, 'imp1', 'a.ged', parsed);
    const key = await deriveKey('pw', randomBytes(16), 1000);
    await addDnaKit(ws.id, parsed.persons[0].id, 'x.txt', parseGenotypeText(toAncestryFormat(syntheticPanel(50))), key);
    const json = await exportWorkspaceJson(ws.id, { includeDna: true });
    const sealed = await sealWithPassphrase('backup-pass', json, 1000);
    expect(JSON.stringify(sealed)).not.toContain('Thornwood');
    await expect(openWithPassphrase('nope', sealed)).rejects.toThrow(/Wrong passphrase/);
    await deleteWorkspace(ws.id);
    expect(await getDb().persons.count()).toBe(0);
    expect(await getDb().dnaKits.count()).toBe(0);
    const restored = await importWorkspaceJson(await openWithPassphrase('backup-pass', sealed));
    expect(restored).toBe(ws.id);
    const d = await loadWorkspaceData(ws.id);
    expect(d.persons).toHaveLength(17);
    expect(await readKitVariants(d.kits[0], key)).toHaveLength(50);
  });
  it('backup without DNA excludes kits', async () => {
    const ws = await createWorkspace('NoDNA');
    const json = await exportWorkspaceJson(ws.id, { includeDna: false });
    expect(JSON.parse(json).tables.dnaKits).toBeUndefined();
  });
});

describe('reviewed merge', () => {
  it('merges two profiles and re-points family links', async () => {
    const { mergePersons } = await import('../database/repo');
    const ws = await createWorkspace('M');
    const parsed = parseGedcom(FAMILY_GED, { workspaceId: ws.id, importId: 'imp1' });
    await commitImport(ws.id, 'imp1', 'a.ged', parsed);
    const keep = parsed.persons.find((p) => p.gedcomId === '@I1@')!;
    const drop = parsed.persons.find((p) => p.gedcomId === '@I17@')!;
    await mergePersons(keep, drop);
    const d = await loadWorkspaceData(ws.id);
    expect(d.persons).toHaveLength(16);
    expect(d.persons.find((p) => p.id === keep.id)!.names.map((n) => n.full)).toContain('Aldrick Thornwood');
    expect(d.graph.children(keep.id)).toHaveLength(2);
  });
});
