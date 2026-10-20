import type { Citation, ExtensionRecord, Family, LifeEvent, Media, Person, Source } from '../../database/types';

export interface ExportInput {
  persons: Person[];
  families: Family[];
  sources: Source[];
  media?: Media[];
  otherRecords?: ExtensionRecord[];
  /** Omit people marked living-private (details) when true. */
  redactLiving?: boolean;
}

function textLines(level: number, tag: string, value: string): string[] {
  const [first, ...rest] = value.split('\n');
  return [`${level} ${tag}${first ? ' ' + first : ''}`, ...rest.map((r) => `${level + 1} CONT ${r}`)];
}

/** Export records as GEDCOM 5.5.1 (UTF-8), preserving original IDs and extension tags where possible. */
export function exportGedcom(input: ExportInput): string {
  const used = new Set<string>();
  const xref = new Map<string, string>();
  const alloc = (id: string, ged: string | undefined, prefix: string) => {
    let x = ged && /^@[^@]+@$/.test(ged) && !used.has(ged) ? ged : undefined;
    let n = xref.size + 1;
    while (!x || used.has(x)) x = `@${prefix}${n++}@`;
    used.add(x);
    xref.set(id, x);
  };
  input.persons.forEach((p) => alloc(p.id, p.gedcomId, 'I'));
  input.families.forEach((f) => alloc(f.id, f.gedcomId, 'F'));
  input.sources.forEach((s) => alloc(s.id, s.gedcomId, 'S'));
  (input.media ?? []).forEach((m) => alloc(m.id, undefined, 'O'));

  const out: string[] = [
    '0 HEAD', '1 GEDC', '2 VERS 5.5.1', '2 FORM LINEAGE-LINKED', '1 CHAR UTF-8',
    '1 SOUR OMNITREE', '2 NAME OmniTree', '2 VERS 0.2.0',
    `1 DATE ${new Date().toUTCString().slice(5, 16).toUpperCase()}`,
  ];

  const cite = (c: Citation, level: number) => {
    const sx = xref.get(c.sourceId);
    if (sx) out.push(`${level} SOUR ${sx}`);
    else if (c.sourceId.startsWith('inline:')) out.push(`${level} SOUR ${c.sourceId.slice(7)}`);
    else return;
    if (c.page) out.push(`${level + 1} PAGE ${c.page}`);
    if (c.quality !== undefined && !Number.isNaN(c.quality)) out.push(`${level + 1} QUAY ${c.quality}`);
    if (c.note) out.push(...textLines(level + 1, 'NOTE', c.note));
  };
  const event = (e: LifeEvent) => {
    if (e.type === '_CITE') { e.citations.forEach((c) => cite(c, 1)); return; }
    out.push(`1 ${e.type}${e.value ? ' ' + e.value : !e.date && !e.place ? ' Y' : ''}`);
    if (e.description) out.push(`2 TYPE ${e.description}`);
    if (e.date?.raw) out.push(`2 DATE ${e.date.raw}`);
    if (e.place) {
      out.push(`2 PLAC ${e.place}`);
      if (e.lat !== undefined && e.lon !== undefined) out.push('3 MAP', `4 LATI ${e.lat < 0 ? 'S' : 'N'}${Math.abs(e.lat)}`, `4 LONG ${e.lon < 0 ? 'W' : 'E'}${Math.abs(e.lon)}`);
    }
    e.citations.forEach((c) => cite(c, 2));
  };

  const famc = new Map<string, { fam: string; rel: string }[]>();
  const fams = new Map<string, string[]>();
  for (const f of input.families) {
    for (const p of f.partnerIds) fams.set(p, [...(fams.get(p) ?? []), f.id]);
    for (const c of f.children) famc.set(c.personId, [...(famc.get(c.personId) ?? []), { fam: f.id, rel: c.relation }]);
  }

  for (const p of input.persons) {
    out.push(`0 ${xref.get(p.id)} INDI`);
    const redact = input.redactLiving && p.privacy === 'living-private';
    if (redact) {
      out.push('1 NAME Living //', '1 RESN privacy');
    } else {
      for (const n of p.names) {
        out.push(`1 NAME ${n.given}${n.given ? ' ' : ''}/${n.surname}/`);
        if (n.given) out.push(`2 GIVN ${n.given}`);
        if (n.surname) out.push(`2 SURN ${n.surname}`);
        if (n.type) out.push(`2 TYPE ${n.type}`);
      }
      if (p.sex) out.push(`1 SEX ${p.sex}`);
      p.events.forEach(event);
      p.notes.forEach((n) => out.push(...textLines(1, 'NOTE', n)));
      p.mediaIds.forEach((m) => xref.has(m) && out.push(`1 OBJE ${xref.get(m)}`));
      p.associations.forEach((a) => {
        if (!xref.has(a.personId)) return;
        out.push(`1 ASSO ${xref.get(a.personId)}`);
        if (a.relation) out.push(`2 RELA ${a.relation}`);
      });
      if (p.privacy === 'living-private') out.push('1 RESN privacy');
      p.extensions.forEach((x) => out.push(...x.lines));
    }
    for (const fc of famc.get(p.id) ?? []) {
      out.push(`1 FAMC ${xref.get(fc.fam)}`);
      if (fc.rel !== 'birth' && fc.rel !== 'unknown') out.push(`2 PEDI ${fc.rel}`);
    }
    for (const fs of fams.get(p.id) ?? []) out.push(`1 FAMS ${xref.get(fs)}`);
  }

  const byId = new Map(input.persons.map((p) => [p.id, p]));
  for (const f of input.families) {
    out.push(`0 ${xref.get(f.id)} FAM`);
    const [a, b] = f.partnerIds.map((id) => byId.get(id));
    const partners = [a, b].filter(Boolean) as Person[];
    // Assign HUSB/WIFE by recorded sex where available, otherwise by order.
    const husb = partners.find((p) => p.sex === 'M') ?? (partners[0]?.sex !== 'F' ? partners[0] : undefined);
    const wife = partners.find((p) => p !== husb);
    if (husb) out.push(`1 HUSB ${xref.get(husb.id)}`);
    if (wife) out.push(`1 WIFE ${xref.get(wife.id)}`);
    f.children.forEach((c) => xref.has(c.personId) && out.push(`1 CHIL ${xref.get(c.personId)}`));
    f.events.forEach(event);
    f.notes.forEach((n) => out.push(...textLines(1, 'NOTE', n)));
    f.extensions.forEach((x) => out.push(...x.lines));
  }

  for (const s of input.sources) {
    out.push(`0 ${xref.get(s.id)} SOUR`, ...textLines(1, 'TITL', s.title));
    if (s.author) out.push(...textLines(1, 'AUTH', s.author));
    if (s.publication) out.push(...textLines(1, 'PUBL', s.publication));
    if (s.text) out.push(...textLines(1, 'TEXT', s.text));
  }
  for (const m of input.media ?? []) {
    out.push(`0 ${xref.get(m.id)} OBJE`, `1 FILE ${m.file}`);
    if (m.format) out.push(`2 FORM ${m.format}`);
    if (m.title) out.push(`2 TITL ${m.title}`);
  }
  (input.otherRecords ?? []).forEach((r) => out.push(...r.lines));
  out.push('0 TRLR');
  return out.join('\n') + '\n';
}
