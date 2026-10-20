import { displayName, eventOf, type ID, type Person } from '../../database/types';
import { dateLabel } from '../../genealogy/gedcom/dates';

const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();

/** N-gram name index for resolving people mentioned in natural language. */
export class NameIndex {
  private byName = new Map<string, ID[]>();
  private tokens = new Map<string, Set<ID>>();
  constructor(private persons: Map<ID, Person>) {
    for (const p of persons.values()) {
      for (const n of p.names) {
        for (const key of new Set([norm(n.full), norm(`${n.given} ${n.surname}`), norm(`${n.given.split(' ')[0]} ${n.surname}`)])) {
          if (!key) continue;
          const arr = this.byName.get(key) ?? [];
          if (!arr.includes(p.id)) arr.push(p.id);
          this.byName.set(key, arr);
        }
        for (const t of norm(n.full).split(' ')) if (t.length > 1) (this.tokens.get(t) ?? this.tokens.set(t, new Set()).get(t)!).add(p.id);
      }
    }
  }

  /** Find person mentions (longest match wins). Each mention may be ambiguous (several IDs). */
  findMentions(text: string): { text: string; ids: ID[] }[] {
    const words = norm(text).split(' ');
    const out: { text: string; ids: ID[] }[] = [];
    for (let i = 0; i < words.length; ) {
      let hit: { len: number; ids: ID[] } | undefined;
      for (let len = Math.min(6, words.length - i); len >= 2; len--) {
        const ids = this.byName.get(words.slice(i, i + len).join(' '));
        if (ids) { hit = { len, ids }; break; }
      }
      if (hit) { out.push({ text: words.slice(i, i + hit.len).join(' '), ids: hit.ids }); i += hit.len; } else i++;
    }
    return out;
  }

  /** Keyword retrieval: rank people by name-token overlap with the query. */
  search(query: string, k = 10): ID[] {
    const score = new Map<ID, number>();
    for (const t of norm(query).split(' ')) for (const id of this.tokens.get(t) ?? []) score.set(id, (score.get(id) ?? 0) + 1);
    return [...score].sort((a, b) => b[1] - a[1]).slice(0, k).map((x) => x[0]);
  }

  /** Compact, DNA-free record summary used as retrieval context for an optional language model. */
  summarize(id: ID): string {
    const p = this.persons.get(id);
    if (!p) return '';
    const ev = p.events.filter((e) => e.type !== '_CITE').slice(0, 6).map((e) => `${e.type} ${dateLabel(e.date)} ${e.place ?? ''}`.trim()).join('; ');
    const living = p.privacy === 'living-private';
    return `[${id}] ${living ? 'Living person (details withheld)' : displayName(p)}${!living && ev ? ' — ' + ev : ''}${eventOf(p, 'BIRT') ? '' : ''}`;
  }
}
