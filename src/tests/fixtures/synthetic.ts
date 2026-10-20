/**
 * Fictional synthetic test data. No real people or real genetic data.
 */

// Tree (all fictional):
//  @I1@ Aldric Thornwood (1850) + @I2@ Mabel Finch (1852)        -> F1
//    children: @I3@ Edwin Thornwood (1875), @I4@ Clara Thornwood (1878)
//  @I3@ Edwin + @I5@ Rose Marlow                                   -> F2: @I6@ Henry Thornwood (1900)
//  @I4@ Clara + @I7@ Silas Brook                                   -> F3: @I8@ Ivy Brook (1902), @I9@ Owen Brook (adopted, 1905)
//  @I6@ Henry + @I10@ June Vale                                    -> F4: @I11@ Arthur Thornwood (1925)
//  @I8@ Ivy + @I12@ Paul Reed                                      -> F5: @I13@ Lena Reed (1928)
//  @I3@ Edwin + @I14@ Grace Holt (second partner)                  -> F6: @I15@ Walter Thornwood (1910) (half-brother of Henry)
//  @I16@ Henry Thornwood (1900, Boston) — a DIFFERENT man with the same name (no shared parents)
//  @I17@ Aldrick Thornwood (1850, Yorkshire) — possible duplicate of @I1@ (same birth year/place, spelling variant)
export const FAMILY_GED = `0 HEAD
1 SOUR SYNTHGEN
2 VERS 1.0
1 GEDC
2 VERS 5.5.1
2 FORM LINEAGE-LINKED
1 CHAR UTF-8
0 @S1@ SOUR
1 TITL Synthetic Parish Register of Eastbrook
1 AUTH Test Archive
0 @S2@ SOUR
1 TITL Synthetic 1910 Census, New York
0 @N1@ NOTE Shared note text
1 CONT continued line
0 @I1@ INDI
1 NAME Aldric /Thornwood/
2 GIVN Aldric
2 SURN Thornwood
1 SEX M
1 BIRT
2 DATE ABT 1850
2 PLAC Eastbrook, Yorkshire, England
2 SOUR @S1@
3 PAGE folio 12
3 QUAY 3
1 DEAT
2 DATE 12 MAR 1920
2 PLAC Eastbrook, Yorkshire, England
1 OCCU Wheelwright
1 _MILT Served in local militia
2 DATE 1870
1 FAMS @F1@
0 @I2@ INDI
1 NAME Mabel /Finch/
1 SEX F
1 BIRT
2 DATE 1852
1 NOTE @N1@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Edwin /Thornwood/
1 SEX M
1 BIRT
2 DATE 4 JUN 1875
2 PLAC Eastbrook, Yorkshire, England
2 SOUR @S1@
1 RESI
2 DATE 1910
2 PLAC Brooklyn, New York, USA
3 MAP
4 LATI N40.65
4 LONG W73.95
2 SOUR @S2@
1 FAMC @F1@
1 FAMS @F2@
1 FAMS @F6@
0 @I4@ INDI
1 NAME Clara /Thornwood/
1 SEX F
1 BIRT
2 DATE BET 1877 AND 1879
1 FAMC @F1@
1 FAMS @F3@
0 @I5@ INDI
1 NAME Rose /Marlow/
1 SEX F
1 FAMS @F2@
0 @I6@ INDI
1 NAME Henry /Thornwood/
1 SEX M
1 BIRT
2 DATE 1900
2 PLAC New York, New York, USA
1 FAMC @F2@
1 FAMS @F4@
0 @I7@ INDI
1 NAME Silas /Brook/
1 SEX M
1 FAMS @F3@
0 @I8@ INDI
1 NAME Ivy /Brook/
1 SEX F
1 BIRT
2 DATE 1902
1 FAMC @F3@
1 FAMS @F5@
0 @I9@ INDI
1 NAME Owen /Brook/
1 SEX M
1 BIRT
2 DATE 1905
1 FAMC @F3@
2 PEDI adopted
0 @I10@ INDI
1 NAME June /Vale/
1 SEX F
1 FAMS @F4@
0 @I11@ INDI
1 NAME Arthur /Thornwood/
1 SEX M
1 BIRT
2 DATE 1925
1 FAMC @F4@
0 @I12@ INDI
1 NAME Paul /Reed/
1 SEX M
1 FAMS @F5@
0 @I13@ INDI
1 NAME Lena /Reed/
1 SEX F
1 BIRT
2 DATE 1928
1 FAMC @F5@
0 @I14@ INDI
1 NAME Grace /Holt/
1 SEX F
1 FAMS @F6@
0 @I15@ INDI
1 NAME Walter /Thornwood/
1 SEX M
1 BIRT
2 DATE 1910
1 FAMC @F6@
0 @I16@ INDI
1 NAME Henry /Thornwood/
1 SEX M
1 BIRT
2 DATE 1900
2 PLAC Boston, Massachusetts, USA
0 @I17@ INDI
1 NAME Aldrick /Thornwood/
1 SEX M
1 BIRT
2 DATE 1850
2 PLAC Eastbrook, Yorkshire, England
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
1 CHIL @I4@
1 MARR
2 DATE 1874
2 PLAC Eastbrook, Yorkshire, England
2 SOUR @S1@
0 @F2@ FAM
1 HUSB @I3@
1 WIFE @I5@
1 CHIL @I6@
0 @F3@ FAM
1 HUSB @I7@
1 WIFE @I4@
1 CHIL @I8@
1 CHIL @I9@
0 @F4@ FAM
1 HUSB @I6@
1 WIFE @I10@
1 CHIL @I11@
0 @F5@ FAM
1 HUSB @I12@
1 WIFE @I8@
1 CHIL @I13@
0 @F6@ FAM
1 HUSB @I3@
1 WIFE @I14@
1 CHIL @I15@
0 @R1@ REPO
1 NAME Synthetic Record Office
0 TRLR
`;

export const GED7 = `0 HEAD
1 GEDC
2 VERS 7.0
0 @I1@ INDI
1 NAME Nora /Quill/
1 SEX F
1 BIRT
2 DATE FROM 1801 TO 1803
1 _CUSTOM something
0 @I2@ INDI
1 NAME Tobias /Quill/
1 FAMC @F1@
0 @F1@ FAM
1 WIFE @I1@
0 TRLR
`;

/** Deterministic PRNG (mulberry32) so synthetic data is reproducible. */
export function rng(seed: number) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Generate a large synthetic GEDCOM (≈ n individuals) with a generational structure. */
export function syntheticLargeGedcom(n: number, seed = 7): string {
  const r = rng(seed);
  const SUR = ['Ashby', 'Crane', 'Dorr', 'Elling', 'Fenn', 'Garrow', 'Hask', 'Ivers', 'Jessop', 'Kell', 'Lark', 'Morrow', 'Nash', 'Orme', 'Pell'];
  const GIV = ['Ada', 'Bram', 'Cora', 'Dell', 'Esme', 'Finn', 'Gwen', 'Hal', 'Iris', 'Jude', 'Kit', 'Lia', 'Max', 'Nell', 'Otto'];
  const lines = ['0 HEAD', '1 GEDC', '2 VERS 5.5.1', '1 CHAR UTF-8'];
  const fams: string[] = [];
  let id = 0;
  let fid = 0;
  const people: { id: number; sex: 'M' | 'F'; year: number; famc?: number; fams: number[] }[] = [];
  const add = (sex: 'M' | 'F', year: number, famc?: number) => { const p = { id: ++id, sex, year, famc, fams: [] as number[] }; people.push(p); return p; };
  let gen = Array.from({ length: 200 }, (_, i) => add(i % 2 ? 'F' : 'M', 1700 + Math.floor(r() * 10)));
  while (id < n) {
    const next: typeof gen = [];
    const men = gen.filter((p) => p.sex === 'M'), women = gen.filter((p) => p.sex === 'F');
    for (let i = 0; i < Math.min(men.length, women.length) && id < n; i++) {
      const f = ++fid;
      men[i].fams.push(f); women[i].fams.push(f);
      const kids: number[] = [];
      const k = 1 + Math.floor(r() * 3);
      for (let c = 0; c < k && id < n; c++) { const kid = add(r() < 0.5 ? 'M' : 'F', men[i].year + 22 + Math.floor(r() * 15), f); kids.push(kid.id); next.push(kid); }
      fams.push(`0 @F${f}@ FAM\n1 HUSB @I${men[i].id}@\n1 WIFE @I${women[i].id}@\n${kids.map((c) => `1 CHIL @I${c}@`).join('\n')}`);
    }
    // Marry in some spouses from outside to keep the population growing.
    for (let i = 0; i < next.length / 3 && id < n; i++) next.push(add(r() < 0.5 ? 'M' : 'F', next[i].year));
    gen = next.sort(() => r() - 0.5);
  }
  for (const p of people) {
    lines.push(`0 @I${p.id}@ INDI`, `1 NAME ${GIV[Math.floor(r() * GIV.length)]} /${SUR[Math.floor(r() * SUR.length)]}/`, `1 SEX ${p.sex}`, '1 BIRT', `2 DATE ${p.year}`);
    if (p.famc) lines.push(`1 FAMC @F${p.famc}@`);
    for (const f of p.fams) lines.push(`1 FAMS @F${f}@`);
  }
  return [...lines, ...fams, '0 TRLR'].join('\n');
}

const ALLELES = ['A', 'C', 'G', 'T'];
/** Synthetic genotype panel: random SNPs with fictional rsIDs. */
export function syntheticPanel(n: number, seed = 1) {
  const r = rng(seed);
  return Array.from({ length: n }, (_, i) => {
    const chrom = String(1 + (i % 22));
    const a = ALLELES[Math.floor(r() * 4)], b = r() < 0.6 ? a : ALLELES[Math.floor(r() * 4)];
    return { rsid: `rs${900000000 + i}`, chrom, pos: 10000 + i * 137, gt: a + b };
  });
}

export function toAncestryFormat(panel: ReturnType<typeof syntheticPanel>, build = '37') {
  const map: Record<string, string> = { X: '23', Y: '24', XY: '25', MT: '26' };
  return [
    '#AncestryDNA raw data download',
    '#This file was generated by a SYNTHETIC test generator (fictional data).',
    `#Genetic data is provided below as five TAB delimited columns... human reference build ${build}`,
    'rsid\tchromosome\tposition\tallele1\tallele2',
    ...panel.map((v) => `${v.rsid}\t${map[v.chrom] ?? v.chrom}\t${v.pos}\t${v.gt === '--' ? '0' : v.gt[0]}\t${v.gt === '--' ? '0' : v.gt[1]}`),
  ].join('\n');
}

export function to23andMeFormat(panel: ReturnType<typeof syntheticPanel>, build = '37') {
  return [
    '# This data file generated by 23andMe (SYNTHETIC TEST FIXTURE — fictional data)',
    `# We are using reference human assembly build ${build} (GRCh${build}).`,
    '# rsid\tchromosome\tposition\tgenotype',
    ...panel.map((v) => `${v.rsid}\t${v.chrom}\t${v.pos}\t${v.gt}`),
  ].join('\n');
}
