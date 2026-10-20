import Dexie, { type Table } from 'dexie';
import type {
  AiResearchSession, AuditEvent, DnaComparison, DnaKit, Family, GedcomImport, HistoricalProfile, Media, Person,
  PrivacyConsent, ResearchHypothesis, Source, TreeWorkspace, ExtensionRecord,
} from './types';

export interface StoredExtension extends ExtensionRecord { id: string; workspaceId: string; importId?: string }
export interface MemoryFact { id: string; workspaceId: string; kind: 'approved-fact' | 'rejected-match' | 'confirmed-match' | 'note'; text: string; personIds: string[]; at: number }

export class OmniDB extends Dexie {
  workspaces!: Table<TreeWorkspace, string>;
  persons!: Table<Person, string>;
  families!: Table<Family, string>;
  sources!: Table<Source, string>;
  media!: Table<Media, string>;
  imports!: Table<GedcomImport, string>;
  extensions!: Table<StoredExtension, string>;
  dnaKits!: Table<DnaKit, string>;
  dnaComparisons!: Table<DnaComparison, string>;
  hypotheses!: Table<ResearchHypothesis, string>;
  historical!: Table<HistoricalProfile, string>;
  aiSessions!: Table<AiResearchSession, string>;
  memory!: Table<MemoryFact, string>;
  audit!: Table<AuditEvent, string>;
  consents!: Table<PrivacyConsent, string>;

  constructor(name = 'omnitree') {
    super(name);
    // Schema migrations: add a new this.version(n) block for each change; never edit old ones.
    this.version(1).stores({
      workspaces: 'id',
      persons: 'id, workspaceId, importId, gedcomId, *dnaKitIds',
      families: 'id, workspaceId, importId, *partnerIds',
      sources: 'id, workspaceId, importId',
      media: 'id, workspaceId',
      imports: 'id, workspaceId, importedAt',
      extensions: 'id, workspaceId, importId',
      dnaKits: 'id, workspaceId, personId',
      dnaComparisons: 'id, kitAId, kitBId',
      hypotheses: 'id, workspaceId, status',
      historical: 'id, personId',
      aiSessions: 'id, workspaceId',
      memory: 'id, workspaceId, kind',
      audit: 'id, workspaceId, at',
      consents: 'id, workspaceId, personId',
    });
  }
}

export const DATA_TABLES = ['workspaces', 'persons', 'families', 'sources', 'media', 'imports', 'extensions', 'dnaKits', 'dnaComparisons', 'hypotheses', 'historical', 'aiSessions', 'memory', 'audit', 'consents'] as const;
export type DataTable = (typeof DATA_TABLES)[number];

let instance: OmniDB | undefined;
export function getDb(): OmniDB {
  instance ??= new OmniDB();
  return instance;
}
export function setDb(db: OmniDB) { instance = db; }

/** Ask the browser not to evict our data under storage pressure. */
export async function requestPersistentStorage(): Promise<boolean | 'unsupported'> {
  if (typeof navigator === 'undefined' || !navigator.storage?.persist) return 'unsupported';
  if (await navigator.storage.persisted()) return true;
  return navigator.storage.persist();
}
