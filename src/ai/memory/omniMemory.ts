import { getDb, type MemoryFact } from '../../database/db';
import { newId, type ID, type ResearchHypothesis } from '../../database/types';
import { audit } from '../../database/repo';

/** OmniMemory: user-approved facts, confirmed/rejected matches and open hypotheses. */
export const OmniMemory = {
  async remember(workspaceId: ID, kind: MemoryFact['kind'], text: string, personIds: ID[] = []) {
    const f: MemoryFact = { id: newId('mem'), workspaceId, kind, text, personIds, at: Date.now() };
    await getDb().memory.add(f);
    return f;
  },
  list(workspaceId: ID) { return getDb().memory.where('workspaceId').equals(workspaceId).reverse().sortBy('at'); },
  async isRejectedPair(workspaceId: ID, a: ID, b: ID) {
    const rows = await getDb().memory.where('workspaceId').equals(workspaceId).filter((m) => m.kind === 'rejected-match').toArray();
    return rows.some((m) => m.personIds.includes(a) && m.personIds.includes(b));
  },
  async addHypothesis(workspaceId: ID, title: string, personIds: ID[], evidence: string[] = []) {
    const h: ResearchHypothesis = { id: newId('hyp'), workspaceId, title, personIds, status: 'open', confidence: 'hypothetical', evidence, createdAt: Date.now(), updatedAt: Date.now() };
    await getDb().hypotheses.add(h);
    await audit(workspaceId, 'create', 'hypothesis', h.id, title);
    return h;
  },
  async setHypothesisStatus(h: ResearchHypothesis, status: ResearchHypothesis['status']) {
    await getDb().hypotheses.put({ ...h, status, updatedAt: Date.now() });
    await audit(h.workspaceId, status, 'hypothesis', h.id, h.title);
  },
  hypotheses(workspaceId: ID) { return getDb().hypotheses.where('workspaceId').equals(workspaceId).toArray(); },
};
