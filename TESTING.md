# Testing

```bash
npm test                 # Vitest: 62 tests across 8 files
npx tsc -p .             # type checking
npm run build            # production build
PLAYWRIGHT_CHROMIUM=/opt/pw-browsers/chromium npm run test:e2e   # end-to-end test
```

Coverage by area:
- `gedcom.test.ts`: date forms, 5.5.1 and 7.0 parsing, extensions, notes, citations, adoption pedigree, malformed-line and broken-reference diagnostics, export round trip, redaction, coordinates.
- `relationships.test.ts`: relationship labels, parents and grandparents, siblings and half-siblings, cousins and "removed", aunts/uncles, adoption and marriage paths, no-path results, double cousins (multiple common ancestors), graph integrity.
- `discovery.test.ts`: duplicate scoring, guards against false positives (same name only, different sex, siblings), Soundex, date/age conflicts, research leads.
- `dna.test.ts`: both provider formats, no-calls, invalid and duplicate rows, PDF rejection, build detection, ZIP files, chromosome and genotype normalization, overlap, conflicts, strand-flip candidates, incompatible builds, different people.
- `database.test.ts` (fake-indexeddb): committing several imports and rolling one back, transaction atomicity, required kit owner, one person with two kits, encryption with the wrong key, DNA kept out of the audit log, privacy of AI summaries, encrypted backup and restore, deletion, reviewed merge.
- `ai.test.ts`: answers grounded in tool results for each command family, asking for clarification on ambiguous names, no made-up answers, DNA comparison.
- `performance.test.ts`: synthetic 15,000-person file. Typical timings: parse about 250 ms, indexing plus queries about 70 ms, duplicate and consistency scans plus export about 2.5 s.
- `v02.test.ts`: gazetteer matching, merge undo that restores people and links exactly, model planner that accepts only supported tools, grounding check against added people, years and cM figures (mock engine).
- `e2e/workflow.spec.ts`: create workspace, preview and commit a GEDCOM import, compute a relationship, set the home person, edit and undo, OmniAI query, map view, upload and link a DNA kit.
