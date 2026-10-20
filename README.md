# OmniTree — World Family Tree

OmniTree is a genealogy web app that runs entirely in your browser and stores everything locally. It imports and exports GEDCOM files, draws interactive trees, and works out relationships between people by searching the family graph. It also analyzes AncestryDNA and 23andMe raw data files and includes **OmniAI**, a research assistant that answers questions from your actual records.

Your data stays in your browser (IndexedDB). There are no accounts and no cloud, and nothing is uploaded.

## Free hosted website (GitHub Pages)

`.github/workflows/deploy.yml` runs the tests, builds the app and publishes it to GitHub Pages, at no cost.

One-time setup by the repository owner: **Settings → Pages → Build and deployment → Source: GitHub Actions**. After that, every push to `main` (or a manual run in the **Actions** tab) deploys to:

**https://froelicherzachary80-collab.github.io/OMNITREE/**

The build uses relative paths and hash routing, so it works under any sub-path and on any static host (Netlify, Cloudflare Pages, Vercel: build command `npm run build`, output folder `dist`). Hosting serves only the app's code; your family data and DNA stay in each visitor's own browser.

## Quick start

```bash
npm install
npm run dev          # http://localhost:5173
npm test             # unit/integration tests (Vitest)
npm run build        # typecheck + production build (dist/)
npm run fixtures     # write synthetic sample files into e2e/fixtures/
npm run test:e2e     # Playwright end-to-end test (builds + previews)
# In environments with a preinstalled Chromium:
PLAYWRIGHT_CHROMIUM=/opt/pw-browsers/chromium npm run test:e2e
```

Requirements: Node 20+ and a modern browser (Safari 16+, Chrome, Firefox, Edge).

To try it out, create a workspace and import `e2e/fixtures/family.ged` (a fictional family). Then upload `e2e/fixtures/synthetic-ancestrydna.txt` and `synthetic-23andme.txt` and link both to the same person.

## New in v0.2
- **Optional local AI model** (WebLLM, needs WebGPU). It picks a tool only when no built-in command matches, and writes a short summary of the tool's facts. A grounding check discards any summary that mentions people, years or DNA figures not in the results.
- **MapLibre world map** with clustering, branch colours and migration lines. Places without recorded coordinates can be shown at approximate positions from an offline gazetteer, marked as such. If the basemap can't load, the offline SVG map is used.
- **Undoable merges** (database schema v2).
- **Per-fact citation editor**: change page and quality, move a citation to another fact, or remove it.
- **Free hosting** through the GitHub Pages workflow.

## What works in v0.1

The full list is in [CHANGELOG.md](CHANGELOG.md), and the known gaps are in [ROADMAP.md](ROADMAP.md).

- **GEDCOM**
  - Imports 5.5, 5.5.1, 7.x and GEDZIP, with a diagnostics preview before anything is saved.
  - Saves in one transaction, and you can undo any import later.
  - Preserves unknown and custom tags, adoption pedigree, citations and coordinates.
  - Exports GEDCOM 5.5.1 that re-imports cleanly, with an option to hide living people.
- **Tree views**
  - Pedigree, fan, descendant, relationship graph (Cytoscape), family group sheet and generation timeline.
  - Profile editing, adding relatives and citations, and undo/redo.
- **PathFinder (relationship calculator)**
  - Names relationships such as cousins and "removed" from the lowest common ancestors.
  - Detects half relationships and multiple common ancestors.
  - Lists adoption and marriage connections separately from blood relationships, and says so when no path exists.
- **Discovery**
  - Duplicate suggestions that need supporting evidence beyond a matching name. Merging always goes through a review screen.
  - Date and age conflict checks, research leads, and surname variant groups.
- **OmniDNA**
  - Parses AncestryDNA and 23andMe files, including zipped ones, in a Web Worker.
  - Reports quality, chromosome distribution and genome build. Each kit must be linked to a person.
  - Compares two kits: overlap, agreement rate, conflicts, possible strand differences and build mismatches.
  - Shows allele-sharing counts between different people, with no relationship claimed from them.
  - SNP lookup.
- **OmniAI**
  - Answers all 14 listed research commands using built-in genealogy tools, with profile IDs, citations and labels for documented, inferred or missing evidence.
  - Asks you to choose when a name matches several people, and saves hypotheses only after you approve them.
- **Privacy**
  - Optional passphrase vault that encrypts DNA kits (AES-256-GCM).
  - Encrypted backup and restore, workspace deletion, an audit log without genetic data, and persistent-storage requests.
- **World Map and Timeline**
  - The map plots only coordinates recorded in your data, with a year slider and generation filter.
  - The timeline groups dated events by decade.
- **App**
  - Installable PWA, light and dark themes, mobile bottom navigation.

## Docs
[ARCHITECTURE.md](ARCHITECTURE.md) · [PRIVACY.md](PRIVACY.md) · [TESTING.md](TESTING.md) · [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)
