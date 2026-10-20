# Roadmap

## v0.1 (this release)
Implemented: see CHANGELOG. Gaps that are known and documented:
- **Local LLM**: only the model catalog and WebGPU detection exist. WebLLM / Transformers.js inference is not wired up yet, and every OmniAI answer comes from the built-in tools.
- **Map**: plots on a graticule without a basemap and does not geocode place names. A MapLibre basemap and a historical gazetteer are still to do.
- **DNA**: no IBD segment detection or centimorgan estimates. No liftover between genome builds; kits on different builds are compared by SNP ID only.
- **GEDCOM**: ANSEL encoding is flagged but not converted. GEDZIP media files are not extracted.
- **Undo** covers profile and family edits. Imports are undone by rolling them back; merges are undone by restoring a backup.
- External connectors (FamilySearch, archives) are not built. Cloud sync is not built.

## v0.2
Optional WebLLM adapter that only selects tools and rephrases their output, with an evaluation set. MapLibre with offline tiles. Merge undo. Field-level citation editor.

## v0.3
Phased-genotype IBD detection, only after it has been validated against published methods. Genome-build liftover tables. Consent workflow for relatives' kits.

## v0.4+
Optional end-to-end encrypted sync. FamilySearch OAuth connector that follows its API terms. Historical gazetteer. Collaboration.

## v1.0
Hardening, an accessibility audit, and performance work for 100k+ people (moving graph indexing into a worker).
