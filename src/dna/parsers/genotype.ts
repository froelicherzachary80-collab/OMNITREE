import type { DnaProvider, VariantCall } from '../../database/types';
import { normalizeChromosome, normalizeGenotype } from '../normalization/normalize';

export interface ParsedKit {
  provider: DnaProvider;
  build?: string;
  buildEvidence?: string;
  variants: VariantCall[];
  noCallCount: number;
  invalidRows: { line: number; reason: string }[];
  duplicateCount: number;
  chromosomeCounts: Record<string, number>;
  headerComments: string[];
}

export class NotGenotypeFileError extends Error {}

/** Detect provider from header comments and column layout. */
export function detectProvider(head: string): DnaProvider {
  if (/AncestryDNA/i.test(head) || /^rsid\tchromosome\tposition\tallele1\tallele2/im.test(head)) return 'ancestrydna';
  if (/23andMe/i.test(head) || /^#\s*rsid\tchromosome\tposition\tgenotype/im.test(head)) return '23andme';
  return 'unknown';
}

/** Determine genome build only from explicit header statements. */
export function detectBuild(comments: string[]): { build?: string; evidence?: string } {
  for (const c of comments) {
    let m = c.match(/GRCh\s?(3[6-8])/i);
    if (m) return { build: `GRCh${m[1]}`, evidence: c.trim() };
    m = c.match(/build\s*(3[6-8])/i);
    if (m) return { build: m[1] === '36' ? 'NCBI36' : `GRCh${m[1]}`, evidence: c.trim() };
    m = c.match(/\bhg(18|19|38)\b/i);
    if (m) return { build: { '18': 'NCBI36', '19': 'GRCh37', '38': 'GRCh38' }[m[1]]!, evidence: c.trim() };
  }
  return {};
}

/** Parse an AncestryDNA or 23andMe raw genotype text file. */
export function parseGenotypeText(text: string): ParsedKit {
  const sample = text.slice(0, 200);
  if (sample.startsWith('%PDF')) throw new NotGenotypeFileError('This is a PDF report, not a raw genotype file.');
  if (/^�|\u0000/.test(sample) || /^(\x89PNG|GIF8|\xFF\xD8)/.test(sample)) throw new NotGenotypeFileError('This looks like an image or binary file, not raw genotype data.');
  const lines = text.split(/\r?\n/);
  const comments: string[] = [];
  let i = 0;
  for (; i < lines.length && (lines[i].startsWith('#') || !lines[i].trim()); i++) if (lines[i].startsWith('#')) comments.push(lines[i]);
  const headProbe = comments.join('\n') + '\n' + lines.slice(i, i + 2).join('\n');
  const provider = detectProvider(headProbe);
  const { build, evidence } = detectBuild(comments);
  const out: ParsedKit = { provider, build, buildEvidence: evidence, variants: [], noCallCount: 0, invalidRows: [], duplicateCount: 0, chromosomeCounts: {}, headerComments: comments };
  const seen = new Set<string>();
  for (; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || line.startsWith('#')) continue;
    const cols = line.split(/\t|,/).map((c) => c.trim().replace(/^"|"$/g, ''));
    if (/^rsid$/i.test(cols[0])) continue; // column header row
    let genotype: string | undefined;
    if (cols.length >= 5) genotype = cols[3] + cols[4];
    else if (cols.length === 4) genotype = cols[3];
    if (!genotype) { out.invalidRows.push({ line: i + 1, reason: 'wrong column count' }); continue; }
    const chrom = normalizeChromosome(cols[1]);
    const pos = Number(cols[2]);
    if (!chrom) { out.invalidRows.push({ line: i + 1, reason: `unknown chromosome "${cols[1]}"` }); continue; }
    if (!Number.isInteger(pos) || pos < 0) { out.invalidRows.push({ line: i + 1, reason: 'invalid position' }); continue; }
    if (!/^(rs\d+|i\d+|[A-Za-z0-9_:.-]+)$/.test(cols[0])) { out.invalidRows.push({ line: i + 1, reason: 'invalid identifier' }); continue; }
    const gt = normalizeGenotype(genotype);
    if (gt === undefined) { out.invalidRows.push({ line: i + 1, reason: `invalid genotype "${genotype}"` }); continue; }
    if (seen.has(cols[0])) { out.duplicateCount++; continue; }
    seen.add(cols[0]);
    if (gt === '--') out.noCallCount++;
    out.chromosomeCounts[chrom] = (out.chromosomeCounts[chrom] ?? 0) + 1;
    out.variants.push({ rsid: cols[0], chrom, pos, genotype: gt });
  }
  if (out.variants.length === 0) throw new NotGenotypeFileError('No genotype rows found. Upload the raw data .txt (or its .zip) from AncestryDNA or 23andMe.');
  return out;
}

/** Compact serialization for storage (one TSV line per variant). */
export function serializeVariants(v: VariantCall[]): string {
  return v.map((x) => `${x.rsid}\t${x.chrom}\t${x.pos}\t${x.genotype}`).join('\n');
}
export function deserializeVariants(s: string): VariantCall[] {
  if (!s) return [];
  return s.split('\n').map((l) => { const [rsid, chrom, pos, genotype] = l.split('\t'); return { rsid, chrom, pos: Number(pos), genotype }; });
}
