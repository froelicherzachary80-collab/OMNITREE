import type { VariantCall } from '../../database/types';
import { complement, isAmbiguousStrand } from '../normalization/normalize';

export interface KitInfo { label: string; build?: string; variants: VariantCall[] }

export interface GenotypeConflict { rsid: string; chrom: string; pos: number; a: string; b: string; note: string }

export interface KitComparison {
  buildsCompatible: boolean | 'unknown';
  buildNote: string;
  totalA: number;
  totalB: number;
  overlap: number;
  onlyA: number;
  onlyB: number;
  bothCalled: number;
  noCallEither: number;
  concordant: number;
  discordant: number;
  /** Discordant calls that equal the reverse complement (possible strand difference; NOT auto-corrected). */
  strandFlipCandidates: number;
  ambiguousStrandSites: number;
  positionMismatches: number;
  concordanceRate?: number;
  conflicts: GenotypeConflict[];
  perChromosome: Record<string, { overlap: number; concordant: number; discordant: number }>;
  /** Plain-language interpretation with explicit limits. */
  interpretation: string[];
}

/**
 * Compare two genotype kits by SNP identifier.
 * Kits are never merged; this reports overlap and agreement so the user can
 * judge whether two files come from the same person (expected ~99%+ concordance)
 * or detect lab/build issues. It makes no relationship claims.
 */
export function compareKits(a: KitInfo, b: KitInfo, maxConflicts = 500): KitComparison {
  const mapB = new Map<string, VariantCall>();
  for (const v of b.variants) mapB.set(v.rsid, v);
  let buildsCompatible: KitComparison['buildsCompatible'] = 'unknown';
  let buildNote = 'Genome build could not be determined for one or both kits; positions are not compared, SNP IDs are.';
  if (a.build && b.build) {
    buildsCompatible = a.build === b.build;
    buildNote = buildsCompatible
      ? `Both kits report ${a.build}; positions are compared.`
      : `Builds differ (${a.build} vs ${b.build}). Comparison uses SNP IDs only; coordinates are not comparable without liftover.`;
  }
  const r: KitComparison = {
    buildsCompatible, buildNote, totalA: a.variants.length, totalB: b.variants.length, overlap: 0, onlyA: 0, onlyB: 0,
    bothCalled: 0, noCallEither: 0, concordant: 0, discordant: 0, strandFlipCandidates: 0, ambiguousStrandSites: 0,
    positionMismatches: 0, conflicts: [], perChromosome: {}, interpretation: [],
  };
  for (const va of a.variants) {
    const vb = mapB.get(va.rsid);
    if (!vb) { r.onlyA++; continue; }
    r.overlap++;
    const pc = (r.perChromosome[va.chrom] ??= { overlap: 0, concordant: 0, discordant: 0 });
    pc.overlap++;
    if (buildsCompatible === true && (va.pos !== vb.pos || va.chrom !== vb.chrom)) r.positionMismatches++;
    if (va.genotype === '--' || vb.genotype === '--') { r.noCallEither++; continue; }
    r.bothCalled++;
    if (isAmbiguousStrand(va.genotype) || isAmbiguousStrand(vb.genotype)) r.ambiguousStrandSites++;
    // Haploid vs diploid representation on X/Y/MT (e.g. "A" vs "AA") is treated as equal.
    const ga = va.genotype.length === 1 ? va.genotype + va.genotype : va.genotype;
    const gb = vb.genotype.length === 1 ? vb.genotype + vb.genotype : vb.genotype;
    if (ga === gb) { r.concordant++; pc.concordant++; continue; }
    r.discordant++; pc.discordant++;
    const flip = complement(ga) === gb && !isAmbiguousStrand(ga);
    if (flip) r.strandFlipCandidates++;
    if (r.conflicts.length < maxConflicts) {
      r.conflicts.push({ rsid: va.rsid, chrom: va.chrom, pos: va.pos, a: va.genotype, b: vb.genotype, note: flip ? 'matches reverse complement (possible strand difference)' : 'genotype disagreement' });
    }
  }
  r.onlyB = r.totalB - r.overlap;
  if (r.bothCalled) r.concordanceRate = r.concordant / r.bothCalled;
  const pct = (x: number) => (x * 100).toFixed(2) + '%';
  if (r.overlap === 0) r.interpretation.push('The kits share no SNP identifiers, so they cannot be compared.');
  else {
    r.interpretation.push(`${r.overlap.toLocaleString()} SNPs appear in both kits; ${r.bothCalled.toLocaleString()} have calls in both.`);
    if (r.concordanceRate !== undefined) {
      r.interpretation.push(`Genotype concordance on overlapping called SNPs: ${pct(r.concordanceRate)}.`);
      if (r.bothCalled < 1000) r.interpretation.push('Overlap is too small for a reliable same-person assessment.');
      else if (r.concordanceRate >= 0.99) r.interpretation.push('This level is consistent with both files coming from the same person (typical genotyping error is under 1%). It does not by itself prove identity.');
      else if (r.concordanceRate >= 0.9) r.interpretation.push('Concordance is lower than expected for one person. Possible causes: strand/build differences, chip errors, or different people.');
      else r.interpretation.push('Concordance is too low for one person. These files most likely come from different people. Raw allele similarity is NOT evidence of a specific family relationship.');
    }
    if (r.strandFlipCandidates) r.interpretation.push(`${r.strandFlipCandidates} conflicts match the reverse complement; these were not auto-corrected.`);
  }
  r.interpretation.push('Combining these files does not produce a complete or clinically accurate genome.');
  return r;
}

/** Same-locus allele sharing between two different people (IBS counts). Not a kinship estimate. */
export function ibsSummary(a: VariantCall[], b: VariantCall[]) {
  const mapB = new Map(b.map((v) => [v.rsid, v.genotype]));
  const ibs = [0, 0, 0];
  for (const v of a) {
    const gb = mapB.get(v.rsid);
    if (!gb || gb === '--' || v.genotype === '--' || v.genotype.length !== 2 || gb.length !== 2) continue;
    const pool = [...gb];
    let shared = 0;
    for (const al of v.genotype) { const k = pool.indexOf(al); if (k >= 0) { shared++; pool.splice(k, 1); } }
    ibs[shared]++;
  }
  const n = ibs[0] + ibs[1] + ibs[2];
  return {
    sites: n, ibs0: ibs[0], ibs1: ibs[1], ibs2: ibs[2],
    note: 'Identity-by-state counts at shared autosomal and other diploid SNPs. IBS0 = 0 shared alleles. This is descriptive only; OmniTree does not yet compute IBD segments or centimorgans, so no relationship is inferred.',
  };
}
