// OmniTree normalized data model. All IDs are stable strings.

export type ID = string;
export type Confidence = 'documented' | 'inferred' | 'hypothetical';
export type PrivacyStatus = 'private' | 'public' | 'living-private';

/** A genealogical date that may be exact, partial, approximate, or a range. */
export interface GenDate {
  raw: string;
  qualifier?: 'ABT' | 'CAL' | 'EST' | 'BEF' | 'AFT' | 'BET' | 'FROM' | 'INT';
  year?: number;
  month?: number;
  day?: number;
  /** For ranges (BET .. AND .., FROM .. TO ..) */
  endYear?: number;
  endMonth?: number;
  endDay?: number;
  /** Sortable approximation of the year; undefined when unparseable. */
  sortYear?: number;
}

export interface PersonName {
  given: string;
  surname: string;
  full: string;
  type?: string; // birth, married, aka...
}

export interface Place {
  id: ID;
  name: string;
  lat?: number;
  lon?: number;
}

export interface LifeEvent {
  id: ID;
  type: string; // BIRT, DEAT, MARR, RESI, OCCU, EVEN...
  date?: GenDate;
  place?: string;
  /** Coordinates only when recorded in the source data (GEDCOM PLAC.MAP); never guessed. */
  lat?: number;
  lon?: number;
  value?: string; // e.g. occupation text
  description?: string;
  citations: Citation[];
}

export interface Citation {
  sourceId: ID;
  page?: string;
  quality?: number; // GEDCOM QUAY 0-3
  note?: string;
}

export interface Source {
  id: ID;
  workspaceId: ID;
  title: string;
  author?: string;
  publication?: string;
  repository?: string;
  text?: string;
  gedcomId?: string;
  importId?: ID;
}

export interface Media {
  id: ID;
  workspaceId: ID;
  file: string;
  format?: string;
  title?: string;
}

/** Unknown / custom GEDCOM structures preserved verbatim. */
export interface ExtensionRecord {
  tag: string;
  value: string;
  lines: string[];
}

export interface Person {
  id: ID;
  workspaceId: ID;
  gedcomId?: string;
  importId?: ID;
  names: PersonName[];
  sex?: 'M' | 'F' | 'X' | 'U';
  events: LifeEvent[];
  notes: string[];
  mediaIds: ID[];
  dnaKitIds: ID[];
  privacy: PrivacyStatus;
  biography?: string;
  researchNotes?: string;
  extensions: ExtensionRecord[];
  associations: { personId: ID; relation?: string }[];
  historical?: boolean; // belongs to the historical / traditional category
  traditional?: boolean; // traditional narrative (e.g. legendary) — not verified history
  updatedAt: number;
}

export type ChildRelation = 'birth' | 'adopted' | 'step' | 'foster' | 'sealing' | 'unknown';

export interface Family {
  id: ID;
  workspaceId: ID;
  gedcomId?: string;
  importId?: ID;
  partnerIds: ID[];
  children: { personId: ID; relation: ChildRelation; fatherRel?: ChildRelation; motherRel?: ChildRelation }[];
  events: LifeEvent[];
  notes: string[];
  extensions: ExtensionRecord[];
  updatedAt: number;
}

export type RelationshipType = 'parent-child' | 'partner' | 'association';

/** Derived edge index used by the graph engine. */
export interface Relationship {
  id: ID;
  workspaceId: ID;
  type: RelationshipType;
  fromId: ID; // parent / partner A
  toId: ID; // child / partner B
  childRelation?: ChildRelation;
  familyId?: ID;
  confidence: Confidence;
}

export interface RelationshipEvidence {
  id: ID;
  relationshipId: ID;
  citation: Citation;
  assessment: Confidence;
  note?: string;
}

export interface GedcomImport {
  id: ID;
  workspaceId: ID;
  fileName: string;
  version?: string;
  sourceSystem?: string;
  charset?: string;
  importedAt: number;
  personCount: number;
  familyCount: number;
  sourceCount: number;
  diagnostics: ImportDiagnostic[];
  header: string[];
  status: 'committed' | 'rolled-back';
}

export interface ImportDiagnostic {
  level: 'info' | 'warning' | 'error';
  line?: number;
  message: string;
}

export type DnaProvider = 'ancestrydna' | '23andme' | 'unknown';

export interface DnaKit {
  id: ID;
  workspaceId: ID;
  personId: ID;
  provider: DnaProvider;
  fileName: string;
  build?: string;
  variantCount: number;
  noCallCount: number;
  invalidRows: number;
  duplicateCount: number;
  chromosomeCounts: Record<string, number>;
  importedAt: number;
  consentNote?: string;
  /** Genotype payload; encrypted when the vault is enabled. */
  encrypted: boolean;
  payload: ArrayBuffer | string;
  iv?: string;
}

export interface VariantCall {
  rsid: string;
  chrom: string;
  pos: number;
  genotype: string; // normalized, alleles sorted, '--' for no-call
}

export interface DnaComparison {
  id: ID;
  kitAId: ID;
  kitBId: ID;
  createdAt: number;
  summary: Record<string, number | string | boolean>;
}

export interface ResearchHypothesis {
  id: ID;
  workspaceId: ID;
  title: string;
  personIds: ID[];
  status: 'open' | 'confirmed' | 'rejected';
  confidence: Confidence;
  evidence: string[];
  createdAt: number;
  updatedAt: number;
}

export interface HistoricalProfile {
  id: ID;
  personId: ID;
  category: 'historical' | 'royal' | 'traditional' | 'legendary';
  sourceNote: string;
}

export interface AiResearchSession {
  id: ID;
  workspaceId: ID;
  createdAt: number;
  messages: { role: 'user' | 'assistant'; text: string; at: number; personIds?: ID[] }[];
}

export interface TreeWorkspace {
  id: ID;
  name: string;
  rootPersonId?: ID;
  createdAt: number;
  vaultEnabled: boolean;
  vaultSalt?: string;
  vaultCheck?: string; // encrypted known string to verify passphrase
  vaultCheckIv?: string;
}

export interface AuditEvent {
  id: ID;
  workspaceId: ID;
  at: number;
  action: string;
  entity: string;
  entityId?: ID;
  /** Never contains DNA genotype data. */
  detail?: string;
}

export interface PrivacyConsent {
  id: ID;
  workspaceId: ID;
  personId: ID;
  scope: 'dna-processing' | 'dna-publish' | 'profile-publish' | 'ai-external';
  granted: boolean;
  at: number;
  note?: string;
}

export const newId = (prefix = 'id'): ID =>
  `${prefix}_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;

export function displayName(p: Pick<Person, 'names'> | undefined): string {
  if (!p) return 'Unknown person';
  const n = p.names[0];
  return n ? n.full || `${n.given} ${n.surname}`.trim() || 'Unnamed' : 'Unnamed';
}

export function eventOf(p: Person, type: string): LifeEvent | undefined {
  return p.events.find((e) => e.type === type);
}
