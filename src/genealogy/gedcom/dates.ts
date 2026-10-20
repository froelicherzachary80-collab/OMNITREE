import type { GenDate } from '../../database/types';

const MONTHS: Record<string, number> = {
  JAN: 1, FEB: 2, MAR: 3, APR: 4, MAY: 5, JUN: 6, JUL: 7, AUG: 8, SEP: 9, OCT: 10, NOV: 11, DEC: 12,
};
const MONTH_NAMES = Object.keys(MONTHS);

interface Simple { year?: number; month?: number; day?: number }

function parseSimple(s: string): Simple | undefined {
  const t = s.trim().replace(/^@#D[A-Z ]+@\s*/, '').replace(/^GREGORIAN\s+/, '');
  if (!t) return undefined;
  const parts = t.split(/\s+/);
  const out: Simple = {};
  for (const part of parts) {
    const up = part.toUpperCase();
    if (MONTHS[up]) out.month = MONTHS[up];
    else if (/^\d{1,2}$/.test(part) && out.month === undefined && out.day === undefined && parts.length === 3) out.day = Number(part);
    else if (/^\d{3,4}(\/\d{2})?$/.test(part)) out.year = Number(part.slice(0, 4).split('/')[0]);
    else if (/^\d{1,2}$/.test(part) && out.day === undefined) out.day = Number(part);
    else if (up === 'BCE' || up === 'BC' || up === 'B.C.') { if (out.year) out.year = -out.year; }
    else return undefined;
  }
  if (out.year === undefined && out.month === undefined) return undefined;
  return out;
}

/** Parse a GEDCOM 5.5/5.5.1/7 date value, keeping the raw value verbatim. */
export function parseGedDate(raw: string): GenDate {
  const value = raw.trim();
  const d: GenDate = { raw: value };
  if (!value) return d;
  const up = value.toUpperCase();
  let m: RegExpMatchArray | null;
  if ((m = up.match(/^BET\s+(.+)\s+AND\s+(.+)$/))) {
    d.qualifier = 'BET';
    assignRange(d, parseSimple(m[1]), parseSimple(m[2]));
  } else if ((m = up.match(/^FROM\s+(.+?)(?:\s+TO\s+(.+))?$/))) {
    d.qualifier = 'FROM';
    assignRange(d, parseSimple(m[1]), m[2] ? parseSimple(m[2]) : undefined);
  } else if ((m = up.match(/^TO\s+(.+)$/))) {
    d.qualifier = 'BEF';
    Object.assign(d, parseSimple(m[1]) ?? {});
  } else if ((m = up.match(/^(ABT|CAL|EST|BEF|AFT|INT)\s+(.+)$/))) {
    d.qualifier = m[1] as GenDate['qualifier'];
    const rest = m[1] === 'INT' ? m[2].replace(/\(.*\)$/, '') : m[2];
    Object.assign(d, parseSimple(rest) ?? {});
  } else {
    Object.assign(d, parseSimple(up) ?? {});
  }
  if (d.year !== undefined) d.sortYear = d.endYear !== undefined ? Math.round((d.year + d.endYear) / 2) : d.year;
  else if (d.endYear !== undefined) d.sortYear = d.endYear;
  return d;
}

function assignRange(d: GenDate, a?: Simple, b?: Simple) {
  if (a) { d.year = a.year; d.month = a.month; d.day = a.day; }
  if (b) { d.endYear = b.year; d.endMonth = b.month; d.endDay = b.day; }
}

/** Build a GEDCOM date string from structured components (used when editing). */
export function formatGedDate(d: Simple & { qualifier?: GenDate['qualifier'] }): string {
  const parts: string[] = [];
  if (d.day) parts.push(String(d.day));
  if (d.month) parts.push(MONTH_NAMES[d.month - 1]);
  if (d.year !== undefined) parts.push(String(d.year));
  const core = parts.join(' ');
  return d.qualifier && d.qualifier !== 'BET' && d.qualifier !== 'FROM' ? `${d.qualifier} ${core}` : core;
}

export function dateLabel(d?: GenDate): string {
  if (!d || !d.raw) return '';
  return d.raw
    .replace(/^ABT /i, 'about ')
    .replace(/^EST /i, 'est. ')
    .replace(/^CAL /i, 'calc. ')
    .replace(/^BEF /i, 'before ')
    .replace(/^AFT /i, 'after ')
    .replace(/^BET (.+) AND (.+)$/i, 'between $1 and $2');
}
