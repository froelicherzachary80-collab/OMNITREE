import { getDb, DATA_TABLES, type StoredExtension } from './db';
import { newId, type AuditEvent, type DnaKit, type Family, type GedcomImport, type ID, type Person, type TreeWorkspace } from './types';
import type { ParsedGedcom } from '../genealogy/gedcom/parser';
import { serializeVariants, deserializeVariants, type ParsedKit } from '../dna/parsers/genotype';
import { decryptText, encryptText, fromB64, toB64 } from '../security/crypto';
import { FamilyGraph } from '../genealogy/graph/familyGraph';

export async function audit(workspaceId: ID, action: string, entity: string, entityId?: ID, detail?: string) {
  const ev: AuditEvent = { id: newId('aud'), workspaceId, at: Date.now(), action, entity, entityId, detail };
  await getDb().audit.add(ev);
}

export async function createWorkspace(name: string): Promise<TreeWorkspace> {
  const ws: TreeWorkspace = { id: newId('ws'), name, createdAt: Date.now(), vaultEnabled: false };
  await getDb().workspaces.add(ws);
  await audit(ws.id, 'create', 'workspace', ws.id, name);
  return ws;
}

export async function updateWorkspace(ws: TreeWorkspace) {
  await getDb().workspaces.put(ws);
}

/** Commit a previewed GEDCOM parse atomically. Everything is tagged with the import id so it can be rolled back. */
export async function commitImport(workspaceId: ID, importId: ID, fileName: string, parsed: ParsedGedcom): Promise<GedcomImport> {
  const db = getDb();
  const rec: GedcomImport = {
    id: importId, workspaceId, fileName, version: parsed.version, sourceSystem: parsed.sourceSystem, charset: parsed.charset,
    importedAt: Date.now(), personCount: parsed.persons.length, familyCount: parsed.families.length, sourceCount: parsed.sources.length,
    diagnostics: parsed.diagnostics, header: parsed.header, status: 'committed',
  };
  const ext: StoredExtension[] = parsed.otherRecords.map((r) => ({ ...r, id: newId('ext'), workspaceId, importId }));
  await db.transaction('rw', [db.persons, db.families, db.sources, db.media, db.imports, db.extensions, db.audit], async () => {
    await db.persons.bulkAdd(parsed.persons);
    await db.families.bulkAdd(parsed.families);
    await db.sources.bulkAdd(parsed.sources);
    await db.media.bulkAdd(parsed.media.map((m) => ({ ...m, workspaceId })));
    await db.extensions.bulkAdd(ext);
    await db.imports.add(rec);
    await audit(workspaceId, 'import', 'gedcom', importId, `${fileName}: ${rec.personCount} people`);
  });
  return rec;
}

/** Remove every record created by an import. Edits made later to those records are removed too. */
export async function rollbackImport(importId: ID) {
  const db = getDb();
  const imp = await db.imports.get(importId);
  if (!imp) throw new Error('Import not found');
  await db.transaction('rw', [db.persons, db.families, db.sources, db.extensions, db.imports, db.audit, db.dnaKits], async () => {
    const people = await db.persons.where('importId').equals(importId).primaryKeys();
    const linkedKits = await db.dnaKits.where('personId').anyOf(people).count();
    if (linkedKits) throw new Error(`Cannot roll back: ${linkedKits} DNA kit(s) are linked to people from this import. Re-assign or delete them first.`);
    await db.persons.bulkDelete(people);
    await db.families.where('importId').equals(importId).delete();
    await db.sources.where('importId').equals(importId).delete();
    await db.extensions.where('importId').equals(importId).delete();
    await db.imports.update(importId, { status: 'rolled-back' });
    // Remove dangling references from families of other imports.
    const peopleSet = new Set(people);
    const fams = await db.families.where('workspaceId').equals(imp.workspaceId).toArray();
    for (const f of fams) {
      const partnerIds = f.partnerIds.filter((p) => !peopleSet.has(p));
      const children = f.children.filter((c) => !peopleSet.has(c.personId));
      if (partnerIds.length !== f.partnerIds.length || children.length !== f.children.length) await db.families.put({ ...f, partnerIds, children });
    }
    await audit(imp.workspaceId, 'rollback', 'gedcom', importId, imp.fileName);
  });
}

export async function loadWorkspaceData(workspaceId: ID) {
  const db = getDb();
  const [persons, families, sources, imports, kits] = await Promise.all([
    db.persons.where('workspaceId').equals(workspaceId).toArray(),
    db.families.where('workspaceId').equals(workspaceId).toArray(),
    db.sources.where('workspaceId').equals(workspaceId).toArray(),
    db.imports.where('workspaceId').equals(workspaceId).toArray(),
    db.dnaKits.where('workspaceId').equals(workspaceId).toArray(),
  ]);
  return { persons, families, sources, imports, kits, graph: new FamilyGraph(persons, families) };
}

export async function savePerson(p: Person, action = 'edit') {
  const next = { ...p, updatedAt: Date.now() };
  await getDb().persons.put(next);
  await audit(p.workspaceId, action, 'person', p.id, p.names[0]?.full);
  return next;
}

export async function deletePerson(p: Person) {
  const db = getDb();
  await db.transaction('rw', [db.persons, db.families, db.audit, db.dnaKits], async () => {
    if (await db.dnaKits.where('personId').equals(p.id).count()) throw new Error('Delete or re-assign this person’s DNA kits first.');
    await db.persons.delete(p.id);
    for (const f of await db.families.where('workspaceId').equals(p.workspaceId).toArray()) {
      if (f.partnerIds.includes(p.id) || f.children.some((c) => c.personId === p.id)) {
        await db.families.put({ ...f, partnerIds: f.partnerIds.filter((x) => x !== p.id), children: f.children.filter((c) => c.personId !== p.id) });
      }
    }
    await audit(p.workspaceId, 'delete', 'person', p.id);
  });
}

export async function saveFamily(f: Family, action = 'edit') {
  await getDb().families.put({ ...f, updatedAt: Date.now() });
  await audit(f.workspaceId, action, 'family', f.id);
}

/** Store a DNA kit linked to its owner; genotypes are encrypted when a vault key is supplied. */
export async function addDnaKit(workspaceId: ID, personId: ID, fileName: string, kit: ParsedKit, key?: CryptoKey, consentNote?: string): Promise<DnaKit> {
  const db = getDb();
  const person = await db.persons.get(personId);
  if (!person) throw new Error('Each DNA kit must belong to an existing person profile');
  const text = serializeVariants(kit.variants);
  let payload: ArrayBuffer | string = text;
  let iv: string | undefined;
  if (key) { const e = await encryptText(key, text); payload = e.data; iv = e.iv; }
  const rec: DnaKit = {
    id: newId('kit'), workspaceId, personId, provider: kit.provider, fileName, build: kit.build,
    variantCount: kit.variants.length, noCallCount: kit.noCallCount, invalidRows: kit.invalidRows.length,
    duplicateCount: kit.duplicateCount, chromosomeCounts: kit.chromosomeCounts, importedAt: Date.now(),
    encrypted: !!key, payload, iv, consentNote,
  };
  await db.transaction('rw', [db.dnaKits, db.persons, db.audit], async () => {
    await db.dnaKits.add(rec);
    await db.persons.put({ ...person, dnaKitIds: [...person.dnaKitIds, rec.id] });
    // Audit records metadata only — never genotypes.
    await audit(workspaceId, 'import', 'dna-kit', rec.id, `${kit.provider} kit (${rec.variantCount} variants) linked to ${person.names[0]?.full ?? personId}`);
  });
  return rec;
}

export async function readKitVariants(kit: DnaKit, key?: CryptoKey) {
  if (!kit.encrypted) return deserializeVariants(kit.payload as string);
  if (!key) throw new Error('Unlock the vault to read this encrypted DNA kit');
  return deserializeVariants(await decryptText(key, kit.iv!, kit.payload as ArrayBuffer));
}

export async function deleteDnaKit(kit: DnaKit) {
  const db = getDb();
  await db.transaction('rw', [db.dnaKits, db.persons, db.audit], async () => {
    await db.dnaKits.delete(kit.id);
    const p = await db.persons.get(kit.personId);
    if (p) await db.persons.put({ ...p, dnaKitIds: p.dnaKitIds.filter((k) => k !== kit.id) });
    await audit(kit.workspaceId, 'delete', 'dna-kit', kit.id);
  });
}

/** Serialize every table for a workspace into JSON (binary payloads base64-encoded). */
export async function exportWorkspaceJson(workspaceId: ID, opts: { includeDna: boolean }): Promise<string> {
  const db = getDb();
  const out: Record<string, unknown[]> = {};
  for (const t of DATA_TABLES) {
    if ((t === 'dnaKits' && !opts.includeDna) || t === 'dnaComparisons' || t === 'historical') continue;
    const table = db.table(t);
    const rows = t === 'workspaces' ? [await table.get(workspaceId)] : await table.where('workspaceId').equals(workspaceId).toArray();
    out[t] = rows.filter(Boolean).map((r) => (t === 'dnaKits' && r.payload instanceof ArrayBuffer ? { ...r, payload: { b64: toB64(r.payload) } } : r));
  }
  return JSON.stringify({ format: 'omnitree-backup', version: 1, exportedAt: new Date().toISOString(), workspaceId, tables: out });
}

export async function importWorkspaceJson(json: string): Promise<ID> {
  const data = JSON.parse(json);
  if (data.format !== 'omnitree-backup') throw new Error('Not an OmniTree backup');
  const db = getDb();
  await db.transaction('rw', DATA_TABLES.map((t) => db.table(t)), async () => {
    for (const [t, rows] of Object.entries<any[]>(data.tables)) {
      if (!(DATA_TABLES as readonly string[]).includes(t)) continue;
      const fixed = rows.map((r) => (t === 'dnaKits' && r.payload?.b64 ? { ...r, payload: fromB64(r.payload.b64).buffer } : r));
      await db.table(t).bulkPut(fixed);
    }
  });
  await audit(data.workspaceId, 'restore', 'workspace', data.workspaceId);
  return data.workspaceId;
}

/** Permanently delete a workspace and all of its data. */
export async function deleteWorkspace(workspaceId: ID) {
  const db = getDb();
  await db.transaction('rw', DATA_TABLES.map((t) => db.table(t)), async () => {
    for (const t of DATA_TABLES) {
      if (t === 'workspaces') await db.workspaces.delete(workspaceId);
      else if (t === 'dnaComparisons' || t === 'historical') continue;
      else if (t === 'merges') await db.merges.where('workspaceId').equals(workspaceId).delete();
      else await db.table(t).where('workspaceId').equals(workspaceId).delete();
    }
  });
}

/** Merge `drop` into `keep` after user review. Names/events/notes are unioned; family links re-pointed. */
export async function mergePersons(keep: Person, drop: Person): Promise<ID> {
  const db = getDb();
  const mergeId = newId('merge');
  await db.transaction('rw', [db.persons, db.families, db.dnaKits, db.audit, db.merges], async () => {
    const touched = (await db.families.where('workspaceId').equals(keep.workspaceId).toArray()).filter((f) => [keep.id, drop.id].some((id) => f.partnerIds.includes(id) || f.children.some((c) => c.personId === id)));
    await db.merges.add({
      id: mergeId, workspaceId: keep.workspaceId, at: Date.now(), keepId: keep.id, dropId: drop.id, undone: false,
      before: { persons: [(await db.persons.get(keep.id))!, (await db.persons.get(drop.id))!], families: touched, kits: await db.dnaKits.where('personId').anyOf([keep.id, drop.id]).toArray() },
    });
    const names = [...keep.names, ...drop.names.filter((n) => !keep.names.some((k) => k.full === n.full)).map((n) => ({ ...n, type: n.type ?? 'aka' }))];
    await db.persons.put({
      ...keep, names, events: [...keep.events, ...drop.events], notes: [...keep.notes, ...drop.notes],
      extensions: [...keep.extensions, ...drop.extensions], mediaIds: [...new Set([...keep.mediaIds, ...drop.mediaIds])],
      dnaKitIds: [...new Set([...keep.dnaKitIds, ...drop.dnaKitIds])], updatedAt: Date.now(),
    });
    for (const k of await db.dnaKits.where('personId').equals(drop.id).toArray()) await db.dnaKits.put({ ...k, personId: keep.id });
    for (const f of await db.families.where('workspaceId').equals(keep.workspaceId).toArray()) {
      if (!f.partnerIds.includes(drop.id) && !f.children.some((c) => c.personId === drop.id)) continue;
      const partnerIds = [...new Set(f.partnerIds.map((p) => (p === drop.id ? keep.id : p)))];
      const seen = new Set<string>();
      const children = f.children.map((c) => (c.personId === drop.id ? { ...c, personId: keep.id } : c)).filter((c) => !seen.has(c.personId) && seen.add(c.personId));
      await db.families.put({ ...f, partnerIds, children, updatedAt: Date.now() });
    }
    await db.persons.delete(drop.id);
    await audit(keep.workspaceId, 'merge', 'person', keep.id, `merged ${drop.id} into ${keep.id}`);
  });
  return mergeId;
}

/** Restore both profiles, their family links and kit owners exactly as they were before the merge. */
export async function undoMerge(mergeId: ID) {
  const db = getDb();
  await db.transaction('rw', [db.persons, db.families, db.dnaKits, db.audit, db.merges], async () => {
    const m = await db.merges.get(mergeId);
    if (!m) throw new Error('Merge not found');
    if (m.undone) throw new Error('This merge was already undone');
    await db.persons.bulkPut(m.before.persons);
    await db.families.bulkPut(m.before.families);
    await db.dnaKits.bulkPut(m.before.kits);
    await db.merges.update(mergeId, { undone: true });
    await audit(m.workspaceId, 'undo-merge', 'person', m.keepId, `restored ${m.dropId}`);
  });
}

export async function reassignDnaKit(kit: DnaKit, personId: ID) {
  const db = getDb();
  await db.transaction('rw', [db.dnaKits, db.persons, db.audit], async () => {
    const from = await db.persons.get(kit.personId);
    const to = await db.persons.get(personId);
    if (!to) throw new Error('Target person not found');
    if (from) await db.persons.put({ ...from, dnaKitIds: from.dnaKitIds.filter((k) => k !== kit.id) });
    await db.persons.put({ ...to, dnaKitIds: [...to.dnaKitIds, kit.id] });
    await db.dnaKits.put({ ...kit, personId });
    await audit(kit.workspaceId, 'reassign', 'dna-kit', kit.id, `to ${personId}`);
  });
}
