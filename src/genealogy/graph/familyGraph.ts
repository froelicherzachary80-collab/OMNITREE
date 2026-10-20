import type { ChildRelation, Family, ID, Person } from '../../database/types';

export interface ParentLink { personId: ID; familyId: ID; relation: ChildRelation }

const BIOLOGICAL: ReadonlySet<ChildRelation> = new Set(['birth', 'unknown']);
export const isBiological = (r: ChildRelation) => BIOLOGICAL.has(r);

/**
 * In-memory adjacency index over persons and families.
 * Built once per workspace load; all queries are O(edges visited).
 */
export class FamilyGraph {
  readonly persons = new Map<ID, Person>();
  readonly families = new Map<ID, Family>();
  private parentsOf = new Map<ID, ParentLink[]>();
  private childrenOf = new Map<ID, ParentLink[]>();
  private partnersOf = new Map<ID, { personId: ID; familyId: ID }[]>();
  private famsOf = new Map<ID, ID[]>();
  private famcOf = new Map<ID, ID[]>();

  constructor(persons: Iterable<Person>, families: Iterable<Family>) {
    for (const p of persons) this.persons.set(p.id, p);
    for (const f of families) this.addFamily(f);
  }

  private push<T>(m: Map<ID, T[]>, k: ID, v: T) {
    const arr = m.get(k);
    if (arr) arr.push(v); else m.set(k, [v]);
  }

  private addFamily(f: Family) {
    this.families.set(f.id, f);
    for (const p of f.partnerIds) {
      this.push(this.famsOf, p, f.id);
      for (const q of f.partnerIds) if (q !== p) this.push(this.partnersOf, p, { personId: q, familyId: f.id });
    }
    for (const c of f.children) {
      this.push(this.famcOf, c.personId, f.id);
      const partners = f.partnerIds;
      partners.forEach((parentId) => {
        const parent = this.persons.get(parentId);
        let rel = c.relation;
        if (parent?.sex === 'M' && c.fatherRel) rel = c.fatherRel;
        if (parent?.sex === 'F' && c.motherRel) rel = c.motherRel;
        this.push(this.parentsOf, c.personId, { personId: parentId, familyId: f.id, relation: rel });
        this.push(this.childrenOf, parentId, { personId: c.personId, familyId: f.id, relation: rel });
      });
    }
  }

  get size() { return this.persons.size; }

  parents(id: ID, biologicalOnly = false): ParentLink[] {
    const ps = this.parentsOf.get(id) ?? [];
    return biologicalOnly ? ps.filter((p) => isBiological(p.relation)) : ps;
  }
  children(id: ID, biologicalOnly = false): ParentLink[] {
    const cs = this.childrenOf.get(id) ?? [];
    return biologicalOnly ? cs.filter((c) => isBiological(c.relation)) : cs;
  }
  partners(id: ID) { return this.partnersOf.get(id) ?? []; }
  spouseFamilies(id: ID) { return (this.famsOf.get(id) ?? []).map((f) => this.families.get(f)!); }
  childFamilies(id: ID) { return (this.famcOf.get(id) ?? []).map((f) => this.families.get(f)!); }

  siblings(id: ID): { personId: ID; kind: 'full' | 'half' | 'step-or-adoptive' }[] {
    const myBio = new Set(this.parents(id, true).map((p) => p.personId));
    const seen = new Map<ID, 'full' | 'half' | 'step-or-adoptive'>();
    for (const fam of this.childFamilies(id)) {
      for (const c of fam.children) {
        if (c.personId === id) continue;
        const theirBio = new Set(this.parents(c.personId, true).map((p) => p.personId));
        const shared = [...myBio].filter((x) => theirBio.has(x)).length;
        const kind = shared >= 2 ? 'full' : shared === 1 ? 'half' : 'step-or-adoptive';
        seen.set(c.personId, kind);
      }
    }
    // Half siblings via a shared biological parent in another family.
    for (const parentId of myBio) {
      for (const c of this.children(parentId, true)) {
        if (c.personId !== id && !seen.has(c.personId)) seen.set(c.personId, 'half');
      }
    }
    return [...seen].map(([personId, kind]) => ({ personId, kind }));
  }

  /** Ancestors with their minimal generation distance. */
  ancestors(id: ID, opts: { maxDepth?: number; biologicalOnly?: boolean; line?: 'paternal' | 'maternal' } = {}): Map<ID, number> {
    const out = new Map<ID, number>();
    let frontier = [id];
    let depth = 0;
    const max = opts.maxDepth ?? Infinity;
    while (frontier.length && depth < max) {
      depth++;
      const next: ID[] = [];
      for (const cur of frontier) {
        let ps = this.parents(cur, opts.biologicalOnly);
        if (depth === 1 && opts.line) {
          const want = opts.line === 'paternal' ? 'M' : 'F';
          ps = ps.filter((p) => this.persons.get(p.personId)?.sex === want);
        }
        for (const p of ps) {
          if (out.has(p.personId) || p.personId === id) continue;
          out.set(p.personId, depth);
          next.push(p.personId);
        }
      }
      frontier = next;
    }
    return out;
  }

  descendants(id: ID, opts: { maxDepth?: number; biologicalOnly?: boolean } = {}): Map<ID, number> {
    const out = new Map<ID, number>();
    let frontier = [id];
    let depth = 0;
    const max = opts.maxDepth ?? Infinity;
    while (frontier.length && depth < max) {
      depth++;
      const next: ID[] = [];
      for (const cur of frontier) for (const c of this.children(cur, opts.biologicalOnly)) {
        if (out.has(c.personId) || c.personId === id) continue;
        out.set(c.personId, depth);
        next.push(c.personId);
      }
      frontier = next;
    }
    return out;
  }

  /** Detect cycles in parent links (a person being their own ancestor) — data integrity check. */
  findAncestryCycles(limit = 20): ID[] {
    const state = new Map<ID, 1 | 2>();
    const cyclic: ID[] = [];
    for (const start of this.persons.keys()) {
      if (state.has(start)) continue;
      const stack: [ID, number][] = [[start, 0]];
      while (stack.length) {
        const top = stack[stack.length - 1];
        const [node, idx] = top;
        if (idx === 0) state.set(node, 1);
        const ps = this.parents(node);
        if (idx < ps.length) {
          top[1]++;
          const nxt = ps[idx].personId;
          const st = state.get(nxt);
          if (st === 1) { cyclic.push(nxt); if (cyclic.length >= limit) return cyclic; }
          else if (!st) stack.push([nxt, 0]);
        } else { state.set(node, 2); stack.pop(); }
      }
    }
    return cyclic;
  }

  /** Longest documented ancestor chain from any person (max generations). */
  maxGenerations(): number {
    const memo = new Map<ID, number>();
    const depth = (id: ID, guard: Set<ID>): number => {
      const m = memo.get(id);
      if (m !== undefined) return m;
      if (guard.has(id)) return 0;
      guard.add(id);
      let best = 0;
      for (const p of this.parents(id)) best = Math.max(best, depth(p.personId, guard));
      guard.delete(id);
      memo.set(id, best + 1);
      return best + 1;
    };
    let max = 0;
    // Iterative-safe for deep trees: process persons without children first is unnecessary; recursion depth = generations.
    for (const id of this.persons.keys()) max = Math.max(max, depth(id, new Set()));
    return max;
  }
}
