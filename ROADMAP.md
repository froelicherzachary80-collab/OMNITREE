# Roadmap

## v0.1 (this release)
Implemented: see CHANGELOG. Gaps that are known and documented:
- **DNA**: no IBD segment detection or centimorgan estimates. No liftover between genome builds; kits on different builds are compared by SNP ID only.
- **GEDCOM**: ANSEL encoding is flagged but not converted. GEDZIP media files are not extracted.
- **Undo** covers profile and family edits, imports (by rollback) and merges (Merge history).
- External connectors (FamilySearch, archives) are not built. Cloud sync is not built.

## v0.2 (done)
WebLLM adapter that only selects tools and summarises their output, behind a grounding check. MapLibre map (online demo basemap with an offline SVG fallback) plus an approximate gazetteer. Merge undo. Field-level citation editor. GitHub Pages deployment.
Still open from v0.2: an evaluation set run against real models (only mocks are tested in CI), offline vector tiles, and a larger gazetteer.

## v0.3
Phased-genotype IBD detection, only after it has been validated against published methods. Genome-build liftover tables. Consent workflow for relatives' kits.

## v0.4+
Optional end-to-end encrypted sync. FamilySearch OAuth connector that follows its API terms. Historical gazetteer. Collaboration.

## v1.0
Hardening, an accessibility audit, and performance work for 100k+ people (moving graph indexing into a worker).
