import { describe, expect, it } from 'vitest';
import { detectBuild, NotGenotypeFileError, parseGenotypeText } from '../dna/parsers/genotype';
import { normalizeChromosome, normalizeGenotype } from '../dna/normalization/normalize';
import { compareKits, ibsSummary } from '../dna/comparisons/compare';
import { loadGenotypeBytes } from '../dna/parsers/loadFile';
import { writeZip } from '../exports/zip';
import { syntheticPanel, to23andMeFormat, toAncestryFormat } from './fixtures/synthetic';

const panel = syntheticPanel(5000, 3);

describe('genotype parsing', () => {
  it('parses AncestryDNA format', () => {
    const k = parseGenotypeText(toAncestryFormat(panel));
    expect(k.provider).toBe('ancestrydna');
    expect(k.build).toBe('GRCh37');
    expect(k.variants).toHaveLength(5000);
    expect(Object.keys(k.chromosomeCounts)).toHaveLength(22);
  });
  it('parses 23andMe format', () => {
    const k = parseGenotypeText(to23andMeFormat(panel));
    expect(k.provider).toBe('23andme');
    expect(k.build).toBe('GRCh37');
    expect(k.variants[0].genotype).toBe([...panel[0].gt].sort().join(''));
  });
  it('counts no-calls, invalid rows and duplicates', () => {
    const t = '# rsid\tchromosome\tposition\tgenotype\nrs1\t1\t100\tAG\nrs2\t1\t200\t--\nrs3\t99\t1\tAA\nrs4\t2\tx\tCC\nrs1\t1\t100\tAG\nrs5\t3\t5\tQQ\n';
    const k = parseGenotypeText(t);
    expect(k.variants).toHaveLength(2);
    expect(k.noCallCount).toBe(1);
    expect(k.duplicateCount).toBe(1);
    expect(k.invalidRows).toHaveLength(3);
  });
  it('rejects PDFs and empty data', () => {
    expect(() => parseGenotypeText('%PDF-1.4 ...')).toThrow(NotGenotypeFileError);
    expect(() => parseGenotypeText('# just a comment\nhello world')).toThrow(NotGenotypeFileError);
  });
  it('detects build only from explicit statements', () => {
    expect(detectBuild(['# build 36'])).toMatchObject({ build: 'NCBI36' });
    expect(detectBuild(['# GRCh38'])).toMatchObject({ build: 'GRCh38' });
    expect(detectBuild(['# nothing here']).build).toBeUndefined();
  });
  it('reads a zipped raw file', async () => {
    const zip = writeZip([{ name: 'AncestryDNA.txt', data: new TextEncoder().encode(toAncestryFormat(panel.slice(0, 100))) }]);
    const k = await loadGenotypeBytes('dna.zip', zip);
    expect(k.variants).toHaveLength(100);
    await expect(loadGenotypeBytes('report.pdf', new Uint8Array([1]))).rejects.toThrow();
  });
});

describe('chromosome normalization', () => {
  it('maps Ancestry numeric codes', () => {
    expect(normalizeChromosome('23')).toBe('X');
    expect(normalizeChromosome('24')).toBe('Y');
    expect(normalizeChromosome('25')).toBe('XY');
    expect(normalizeChromosome('26')).toBe('MT');
    expect(normalizeChromosome('chr7')).toBe('7');
    expect(normalizeChromosome('M')).toBe('MT');
    expect(normalizeChromosome('30')).toBeUndefined();
  });
  it('normalizes unordered genotypes and no-calls', () => {
    expect(normalizeGenotype('GA')).toBe('AG');
    expect(normalizeGenotype('00')).toBe('--');
    expect(normalizeGenotype('A')).toBe('A');
    expect(normalizeGenotype('ZZ')).toBeUndefined();
  });
});

describe('multi-kit comparison', () => {
  const a = parseGenotypeText(toAncestryFormat(panel));
  it('same person, two providers → high concordance, overlap counted', () => {
    const partial = panel.slice(1000);
    const b = parseGenotypeText(to23andMeFormat(partial));
    const r = compareKits({ label: 'a', build: a.build, variants: a.variants }, { label: 'b', build: b.build, variants: b.variants });
    expect(r.overlap).toBe(4000);
    expect(r.onlyA).toBe(1000);
    expect(r.onlyB).toBe(0);
    expect(r.concordanceRate).toBe(1);
    expect(r.buildsCompatible).toBe(true);
  });
  it('detects conflicting genotype calls and strand-flip candidates without correcting', () => {
    const changed = panel.map((v) => ({ ...v }));
    changed[0].gt = 'AG'; changed[1].gt = 'CC'; // reference for kit A
    const base = parseGenotypeText(toAncestryFormat(changed));
    const other = changed.map((v) => ({ ...v }));
    other[0].gt = 'CT'; // reverse complement of AG → strand-flip candidate
    other[1].gt = 'AA'; // plain conflict
    const b = parseGenotypeText(to23andMeFormat(other));
    const r = compareKits({ label: 'a', build: base.build, variants: base.variants }, { label: 'b', build: b.build, variants: b.variants });
    expect(r.discordant).toBe(2);
    expect(r.strandFlipCandidates).toBe(1);
    expect(r.conflicts.map((c) => c.note)).toEqual(['matches reverse complement (possible strand difference)', 'genotype disagreement']);
    expect(b.variants[0].genotype).toBe('CT'); // never auto-corrected
  });
  it('flags incompatible genome builds and skips position comparison', () => {
    const b = parseGenotypeText(to23andMeFormat(panel.map((v) => ({ ...v, pos: v.pos + 5 })), '38'));
    const r = compareKits({ label: 'a', build: a.build, variants: a.variants }, { label: 'b', build: b.build, variants: b.variants });
    expect(r.buildsCompatible).toBe(false);
    expect(r.positionMismatches).toBe(0);
    expect(r.buildNote).toMatch(/Builds differ/);
  });
  it('different people → low concordance, no relationship claimed', () => {
    const other = parseGenotypeText(to23andMeFormat(syntheticPanel(5000, 99)));
    const r = compareKits({ label: 'a', build: a.build, variants: a.variants }, { label: 'b', build: other.build, variants: other.variants });
    expect(r.concordanceRate!).toBeLessThan(0.9);
    expect(r.interpretation.join(' ')).toMatch(/NOT evidence of a specific family relationship/);
    const ibs = ibsSummary(a.variants, other.variants);
    expect(ibs.sites).toBeGreaterThan(0);
    expect(ibs.note).toMatch(/no relationship is inferred/);
  });
});
