import {
  newId, type Citation, type ChildRelation, type ExtensionRecord, type Family, type ImportDiagnostic,
  type LifeEvent, type Media, type Person, type PersonName, type Source,
} from '../../database/types';
import { parseGedDate } from './dates';

/** A node in the GEDCOM line tree. */
export interface GedNode {
  level: number;
  xref?: string;
  tag: string;
  value: string;
  line: number;
  children: GedNode[];
}

export interface ParsedGedcom {
  version?: string;
  sourceSystem?: string;
  charset?: string;
  header: string[];
  persons: Person[];
  families: Family[];
  sources: Source[];
  media: Media[];
  /** Top-level records that are not INDI/FAM/SOUR/OBJE/HEAD/TRLR (e.g. REPO, SUBM, _custom). */
  otherRecords: ExtensionRecord[];
  diagnostics: ImportDiagnostic[];
}

const LINE_RE = /^\s*(\d{1,2})\s+(?:(@[^@]+@)\s+)?([A-Za-z0-9_]+)(?:\s(.*))?$/;

/** Tokenize GEDCOM text into a node tree, reporting malformed lines. */
export function tokenize(text: string, diagnostics: ImportDiagnostic[]): GedNode[] {
  const roots: GedNode[] = [];
  const stack: GedNode[] = [];
  const lines = text.replace(/^﻿/, '').split(/\r\n|\r|\n/);
  lines.forEach((rawLine, i) => {
    if (!rawLine.trim()) return;
    const m = rawLine.match(LINE_RE);
    if (!m) {
      diagnostics.push({ level: 'error', line: i + 1, message: `Malformed line skipped: "${rawLine.slice(0, 80)}"` });
      return;
    }
    const level = Number(m[1]);
    const node: GedNode = { level, xref: m[2], tag: m[3].toUpperCase(), value: m[4] ?? '', line: i + 1, children: [] };
    if (node.tag === 'CONT' || node.tag === 'CONC') {
      const parent = stack[level - 1];
      if (parent && stack.length >= level) {
        parent.value += (node.tag === 'CONT' ? '\n' : '') + node.value;
        stack.length = level;
        return;
      }
    }
    while (stack.length > level) stack.pop();
    if (level === 0) roots.push(node);
    else if (stack[level - 1]) stack[level - 1].children.push(node);
    else {
      diagnostics.push({ level: 'error', line: i + 1, message: `Level ${level} line has no parent; skipped` });
      return;
    }
    stack[level] = node;
  });
  return roots;
}

/** Serialize a node back to GEDCOM lines (for preserving unknown structures). */
export function nodeToLines(n: GedNode, level = n.level): string[] {
  const head = `${level}${n.xref ? ' ' + n.xref : ''} ${n.tag}`;
  const [first, ...rest] = n.value.split('\n');
  const out = [first ? `${head} ${first}` : head];
  for (const r of rest) out.push(`${level + 1} CONT ${r}`);
  for (const c of n.children) out.push(...nodeToLines(c, level + 1));
  return out;
}

const child = (n: GedNode, tag: string) => n.children.find((c) => c.tag === tag);
const childrenOf = (n: GedNode, tag: string) => n.children.filter((c) => c.tag === tag);

const INDI_EVENTS = new Set(['BIRT', 'CHR', 'BAPM', 'DEAT', 'BURI', 'CREM', 'ADOP', 'RESI', 'OCCU', 'EVEN', 'EDUC', 'EMIG', 'IMMI', 'NATU', 'CENS', 'PROB', 'WILL', 'GRAD', 'RETI', 'RELI', 'TITL', 'NATI', 'CONF', 'FCOM', 'ORDN', 'DSCR', 'FACT']);
const FAM_EVENTS = new Set(['MARR', 'DIV', 'ENGA', 'MARB', 'MARC', 'MARL', 'MARS', 'ANUL', 'DIVF', 'EVEN', 'RESI', 'CENS']);
const KNOWN_INDI = new Set(['NAME', 'SEX', 'FAMC', 'FAMS', 'NOTE', 'OBJE', 'SOUR', 'ASSO', 'CHAN', 'RIN', 'UID', '_UID', 'RESN', 'REFN']);
const KNOWN_FAM = new Set(['HUSB', 'WIFE', 'CHIL', 'NOTE', 'SOUR', 'OBJE', 'CHAN', 'RIN', 'UID', '_UID', 'NCHI', 'REFN']);

function parseCitations(n: GedNode, sourceIdMap: Map<string, string>, diagnostics: ImportDiagnostic[]): Citation[] {
  return childrenOf(n, 'SOUR').map((s) => {
    let sourceId = sourceIdMap.get(s.value);
    if (!sourceId) {
      if (s.value.startsWith('@')) diagnostics.push({ level: 'warning', line: s.line, message: `Citation references missing source ${s.value}` });
      sourceId = s.value.startsWith('@') ? `missing:${s.value}` : `inline:${s.value}`;
    }
    const quay = child(s, 'QUAY');
    return {
      sourceId,
      page: child(s, 'PAGE')?.value,
      quality: quay ? Number(quay.value) : undefined,
      note: child(s, 'NOTE')?.value,
    };
  });
}

function parseEvent(n: GedNode, sourceIdMap: Map<string, string>, diagnostics: ImportDiagnostic[]): LifeEvent {
  const date = child(n, 'DATE');
  const type = child(n, 'TYPE');
  const plac = child(n, 'PLAC');
  const map = plac && child(plac, 'MAP');
  const coord = (v: string | undefined, neg: string) => (v ? (v.toUpperCase().startsWith(neg) ? -1 : 1) * Number(v.replace(/^[NSEW]/i, '')) : undefined);
  return {
    lat: map ? coord(child(map, 'LATI')?.value, 'S') : undefined,
    lon: map ? coord(child(map, 'LONG')?.value, 'W') : undefined,
    id: newId('ev'),
    type: n.tag,
    date: date ? parseGedDate(date.value) : undefined,
    place: child(n, 'PLAC')?.value,
    value: n.value && n.value !== 'Y' ? n.value : undefined,
    description: type?.value,
    citations: parseCitations(n, sourceIdMap, diagnostics),
  };
}

function parseName(n: GedNode): PersonName {
  const m = n.value.match(/^(.*?)\/(.*?)\/(.*)$/);
  let given = child(n, 'GIVN')?.value ?? (m ? m[1].trim() : n.value.trim());
  let surname = child(n, 'SURN')?.value ?? (m ? m[2].trim() : '');
  const suffix = m ? m[3].trim() : '';
  given = given.trim(); surname = surname.trim();
  return { given, surname, full: [given, surname, suffix].filter(Boolean).join(' '), type: child(n, 'TYPE')?.value };
}

function mapPedi(v?: string): ChildRelation {
  switch ((v ?? '').toLowerCase()) {
    case 'birth': return 'birth';
    case 'adopted': return 'adopted';
    case 'foster': return 'foster';
    case 'sealing': return 'sealing';
    case 'step': return 'step';
    case '': return 'birth';
    default: return 'unknown';
  }
}

export interface ParseOptions { workspaceId: string; importId: string }

/** Parse a GEDCOM document (5.5, 5.5.1 or 7.x) into OmniTree records without touching the database. */
export function parseGedcom(text: string, opts: ParseOptions): ParsedGedcom {
  const diagnostics: ImportDiagnostic[] = [];
  const roots = tokenize(text, diagnostics);
  const out: ParsedGedcom = { header: [], persons: [], families: [], sources: [], media: [], otherRecords: [], diagnostics };
  const now = Date.now();

  const head = roots.find((r) => r.tag === 'HEAD');
  if (!head) diagnostics.push({ level: 'warning', message: 'No HEAD record found; file may not be GEDCOM.' });
  else {
    out.header = nodeToLines(head);
    out.version = child(child(head, 'GEDC') ?? head, 'VERS')?.value;
    out.sourceSystem = child(head, 'SOUR')?.value;
    out.charset = child(head, 'CHAR')?.value;
    if (out.charset && /ANSEL/i.test(out.charset)) diagnostics.push({ level: 'warning', message: 'ANSEL character set detected; non-ASCII characters may need review.' });
  }
  if (!roots.some((r) => r.tag === 'TRLR')) diagnostics.push({ level: 'warning', message: 'Missing TRLR record; file may be truncated.' });

  // Allocate IDs first so references resolve regardless of order.
  const personIds = new Map<string, string>();
  const familyIds = new Map<string, string>();
  const sourceIds = new Map<string, string>();
  const mediaIds = new Map<string, string>();
  const noteRecords = new Map<string, string>();
  const duplicates = new Set<GedNode>();
  for (const r of roots) {
    if (!r.xref) continue;
    const map = r.tag === 'INDI' ? personIds : r.tag === 'FAM' ? familyIds : r.tag === 'SOUR' ? sourceIds : r.tag === 'OBJE' ? mediaIds : undefined;
    if (r.tag === 'NOTE' || r.tag === 'SNOTE') noteRecords.set(r.xref, r.value);
    if (!map) continue;
    if (map.has(r.xref)) {
      diagnostics.push({ level: 'error', line: r.line, message: `Duplicate record ID ${r.xref}; later record not imported (kept in diagnostics)` });
      duplicates.add(r);
      continue;
    }
    map.set(r.xref, newId(r.tag.toLowerCase()));
  }
  const resolveNote = (n: GedNode) => (n.value.startsWith('@') && noteRecords.has(n.value) ? noteRecords.get(n.value)! : n.value);

  for (const r of roots) {
    if (duplicates.has(r)) continue;
    switch (r.tag) {
      case 'HEAD': case 'TRLR': case 'NOTE': case 'SNOTE': break;
      case 'SOUR':
        out.sources.push({
          id: sourceIds.get(r.xref!)!, workspaceId: opts.workspaceId, importId: opts.importId, gedcomId: r.xref,
          title: child(r, 'TITL')?.value ?? child(r, 'ABBR')?.value ?? r.xref ?? 'Untitled source',
          author: child(r, 'AUTH')?.value, publication: child(r, 'PUBL')?.value,
          repository: child(r, 'REPO')?.value, text: child(r, 'TEXT')?.value,
        });
        break;
      case 'OBJE':
        out.media.push({
          id: mediaIds.get(r.xref!)!, workspaceId: opts.workspaceId,
          file: child(r, 'FILE')?.value ?? '', format: child(child(r, 'FILE') ?? r, 'FORM')?.value,
          title: child(r, 'TITL')?.value ?? child(child(r, 'FILE') ?? r, 'TITL')?.value,
        });
        break;
      case 'INDI': {
        if (!r.xref) { diagnostics.push({ level: 'error', line: r.line, message: 'INDI without ID skipped' }); break; }
        const p: Person = {
          id: personIds.get(r.xref)!, workspaceId: opts.workspaceId, importId: opts.importId, gedcomId: r.xref,
          names: childrenOf(r, 'NAME').map(parseName), events: [], notes: [], mediaIds: [], dnaKitIds: [],
          privacy: 'private', extensions: [], associations: [], updatedAt: now,
        };
        const sex = child(r, 'SEX')?.value.trim().toUpperCase();
        if (sex) p.sex = (['M', 'F', 'X', 'U'].includes(sex) ? sex : 'U') as Person['sex'];
        if (!p.names.length) diagnostics.push({ level: 'warning', line: r.line, message: `${r.xref} has no NAME` });
        for (const c of r.children) {
          if (INDI_EVENTS.has(c.tag)) p.events.push(parseEvent(c, sourceIds, diagnostics));
          else if (c.tag === 'NOTE') p.notes.push(resolveNote(c));
          else if (c.tag === 'OBJE') {
            if (mediaIds.has(c.value)) p.mediaIds.push(mediaIds.get(c.value)!);
            else if (child(c, 'FILE')) {
              const mid = newId('obje');
              out.media.push({ id: mid, workspaceId: opts.workspaceId, file: child(c, 'FILE')!.value, title: child(c, 'TITL')?.value });
              p.mediaIds.push(mid);
            }
          } else if (c.tag === 'ASSO') {
            const pid = personIds.get(c.value);
            if (pid) p.associations.push({ personId: pid, relation: (child(c, 'RELA') ?? child(c, 'ROLE'))?.value });
            else diagnostics.push({ level: 'warning', line: c.line, message: `ASSO references missing person ${c.value}` });
          } else if (c.tag === 'SOUR') {
            // Person-level citation: keep as a pseudo-event so provenance is not lost.
            p.events.push({ id: newId('ev'), type: '_CITE', citations: parseCitations({ ...r, children: [c] }, sourceIds, diagnostics) });
          } else if (c.tag === 'RESN' && /privacy|confidential/i.test(c.value)) p.privacy = 'living-private';
          else if (!KNOWN_INDI.has(c.tag)) p.extensions.push({ tag: c.tag, value: c.value, lines: nodeToLines(c, 1) });
        }
        out.persons.push(p);
        break;
      }
      case 'FAM': {
        if (!r.xref) { diagnostics.push({ level: 'error', line: r.line, message: 'FAM without ID skipped' }); break; }
        const f: Family = {
          id: familyIds.get(r.xref)!, workspaceId: opts.workspaceId, importId: opts.importId, gedcomId: r.xref,
          partnerIds: [], children: [], events: [], notes: [], extensions: [], updatedAt: now,
        };
        for (const c of r.children) {
          if (c.tag === 'HUSB' || c.tag === 'WIFE') {
            const pid = personIds.get(c.value);
            if (pid) f.partnerIds.push(pid);
            else diagnostics.push({ level: 'warning', line: c.line, message: `${r.xref} ${c.tag} references missing person ${c.value}` });
          } else if (c.tag === 'CHIL') {
            const pid = personIds.get(c.value);
            if (!pid) { diagnostics.push({ level: 'warning', line: c.line, message: `${r.xref} CHIL references missing person ${c.value}` }); continue; }
            f.children.push({ personId: pid, relation: 'birth' });
          } else if (FAM_EVENTS.has(c.tag)) f.events.push(parseEvent(c, sourceIds, diagnostics));
          else if (c.tag === 'NOTE') f.notes.push(resolveNote(c));
          else if (!KNOWN_FAM.has(c.tag)) f.extensions.push({ tag: c.tag, value: c.value, lines: nodeToLines(c, 1) });
        }
        out.families.push(f);
        break;
      }
      default:
        out.otherRecords.push({ tag: r.tag, value: r.value, lines: nodeToLines(r) });
        diagnostics.push({ level: 'info', line: r.line, message: `Preserved ${r.tag} record ${r.xref ?? ''} as extension` });
    }
  }

  // Second pass: FAMC pedigree / adoption details on individuals.
  const famByGed = new Map(out.families.map((f) => [f.gedcomId!, f]));
  for (const r of roots.filter((x) => x.tag === 'INDI' && x.xref && !duplicates.has(x))) {
    const pid = personIds.get(r.xref!)!;
    for (const famc of childrenOf(r, 'FAMC')) {
      const fam = famByGed.get(famc.value);
      if (!fam) { diagnostics.push({ level: 'warning', line: famc.line, message: `${r.xref} FAMC references missing family ${famc.value}` }); continue; }
      let entry = fam.children.find((c) => c.personId === pid);
      if (!entry) {
        entry = { personId: pid, relation: 'birth' };
        fam.children.push(entry);
        diagnostics.push({ level: 'info', line: famc.line, message: `${r.xref} linked to ${famc.value} via FAMC only (no CHIL)` });
      }
      const pedi = child(famc, 'PEDI');
      if (pedi) entry.relation = mapPedi(pedi.value);
    }
    // ADOP event with FAMC/ADOP qualifier marks adoptive family.
    for (const adop of childrenOf(r, 'ADOP')) {
      const famc = child(adop, 'FAMC');
      const fam = famc && famByGed.get(famc.value);
      const entry = fam?.children.find((c) => c.personId === pid);
      if (entry) {
        entry.relation = 'adopted';
        const by = child(famc!, 'ADOP')?.value?.toUpperCase();
        if (by === 'HUSB') entry.motherRel = 'birth';
        if (by === 'WIFE') entry.fatherRel = 'birth';
      }
    }
    for (const fams of childrenOf(r, 'FAMS')) {
      const fam = famByGed.get(fams.value);
      if (fam && !fam.partnerIds.includes(pid)) fam.partnerIds.push(pid);
    }
  }

  diagnostics.unshift({
    level: 'info',
    message: `Parsed GEDCOM ${out.version ?? '(unknown version)'}: ${out.persons.length} individuals, ${out.families.length} families, ${out.sources.length} sources, ${out.media.length} media`,
  });
  return out;
}
