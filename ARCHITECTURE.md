# Architecture

```
src/
  app/          React shell, hash router, global store (workspace, graph, undo/redo)
  pages/        One component per navigation tab (lazy-loaded)
  components/   Shared UI, SVG charts (pedigree/fan/descendant), Cytoscape graph, profile editor
  database/     Data model (types.ts), Dexie schema + migrations (db.ts), transactional repository (repo.ts)
  genealogy/
    gedcom/     Line tokenizer, parser (5.5/5.5.1/7), date parser, exporter
    graph/      FamilyGraph adjacency index (parents/children/partners, ancestors, cycles)
    relationships/ PathFinder: LCA blood relationships + typed BFS for affinity/adoptive paths
    discovery/  Duplicate scoring (Soundex blocking), consistency checks, research leads
  dna/
    parsers/    Provider detection, genotype parsing, ZIP loading
    normalization/ Chromosome + genotype normalization, strand helpers
    comparisons/ Multi-kit comparison, IBS summary
    workers/    Web Worker + client for parse/compare jobs
  ai/
    agent/      OmniAgent: intent routing → tools → grounded answer composition
    tools/      Deterministic genealogy tools (each returns facts with basis + source IDs)
    retrieval/  NameIndex (n-gram mention resolution, keyword retrieval, DNA-free summaries)
    memory/     OmniMemory: approved facts, rejected/confirmed matches, hypotheses
    models/     Model catalog, capability detection, WebLLM loader, tool planner and grounding check
  maps/         Offline gazetteer (approximate centroids) and MapLibre view
  security/     WebCrypto PBKDF2 + AES-GCM, vault, sealed backups
  exports/      ZIP reader/writer
  tests/        Vitest suites + synthetic fixtures
```

## Key decisions
- **Raw claims vs accepted facts**: imports keep their `importId`, `gedcomId`, citations and extension lines, so you can always trace where data came from or remove an import. Hypotheses live in their own table and never change relationships.
- **Graph**: `FamilyGraph` is rebuilt from IndexedDB whenever the workspace reloads. Families are the source of truth; parent/child/partner edges are derived from them. Adoptive, step and foster links are typed and excluded from blood calculations.
- **Relationship naming**: PathFinder runs a breadth-first search up each person's biological ancestry to find the lowest common ancestors. Two ancestors who are partners count as one couple. A relationship is "half" when the two lines come down from the ancestor through different families.
- **Scale**: charts render only the requested generations, and graph views show a limited neighbourhood. A 15,000-person file imports and indexes in well under a second (see TESTING.md).
- **OmniAI**: there is no generative model in the loop. Each intent maps to a tool, and the answer is built only from the tool's results. A future local LLM may choose tools and rephrase their output, but it cannot add facts.
- **Migrations**: Dexie `version(n)` blocks in `database/db.ts`. Add new versions; never edit old ones.
