const CHROM_ALIASES: Record<string, string> = { '23': 'X', '24': 'Y', '25': 'XY', '26': 'MT', M: 'MT', MT: 'MT', X: 'X', Y: 'Y', XY: 'XY' };

/** Normalize chromosome labels from both providers (Ancestry uses 23-26 numeric codes). */
export function normalizeChromosome(c: string): string | undefined {
  const t = c.trim().toUpperCase().replace(/^CHR/, '');
  if (/^\d+$/.test(t)) {
    const n = Number(t);
    if (n >= 1 && n <= 22) return String(n);
    return CHROM_ALIASES[String(n)];
  }
  return CHROM_ALIASES[t];
}

export const CHROMOSOME_ORDER = [...Array.from({ length: 22 }, (_, i) => String(i + 1)), 'X', 'Y', 'XY', 'MT'];

/**
 * Normalize a genotype string. Alleles are sorted so "GA" and "AG" compare equal
 * (genotype calls are unphased). No-calls ("--", "00", "0 0") become "--".
 * Returns undefined for unrecognized values.
 */
export function normalizeGenotype(g: string): string | undefined {
  const t = g.trim().toUpperCase().replace(/\s+/g, '');
  if (t === '--' || t === '00' || t === '0' || t === '-' || t === '') return '--';
  if (!/^[ACGTDI]{1,2}$/.test(t)) return undefined;
  return t.length === 1 ? t : [...t].sort().join('');
}

const COMP: Record<string, string> = { A: 'T', T: 'A', C: 'G', G: 'C', D: 'D', I: 'I' };
export const complement = (g: string) => (g === '--' ? g : [...g].map((c) => COMP[c] ?? c).sort().join(''));

/** A/T and C/G SNPs cannot be strand-resolved from genotypes alone. */
export const isAmbiguousStrand = (g: string) => g === 'AT' || g === 'CG';
