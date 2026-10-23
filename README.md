# Multiverse Tree

A native iOS app (Swift, SwiftUI, Metal) that shows documented connections between people (family, creators, celebrities, historical figures and friends) as one glowing, interactive network of cosmic branches. Every branch is a stored relationship with sources.

> **Version 0.1.** The engine (graph database, pathfinding, genealogy, research agents, AI orchestration) is built and passes 54 unit and integration tests on Linux. The iOS app target (SwiftUI screens and Metal renderer) is written in full but **has not been compiled yet**: the environment it was written in has no Xcode. The `ios-app` CI job, or one build on a Mac, is the first real compile. See [Status](#status--what-remains).

---

## Repository layout

```
Package.swift                     Swift package: MultiverseCore library, mvt CLI, tests
Sources/
  CSQLite/                        system SQLite module map
  MultiverseCore/
    Model/                        Person, Identity, Relationship, Evidence, Source, jobs, merge proposals …
    Database/                     SQLite wrapper, versioned schema/migrations, GraphStore (evidence-backed CRUD)
    Graph/                        CSR GraphIndex, EdgeFilter, PathFinder (BFS, bidirectional BFS, Dijkstra, Yen K-shortest,
                                  components, label-propagation communities)
    Genealogy/                    GEDCOM parser/importer/exporter, kinship & common-ancestor maths, MergeEngine
    Research/                     rate-limited cached HTTP, Wikidata/Wikipedia/YouTube connectors, research agents,
                                  source verification, persistent ResearchScheduler, source dashboard registry
    Intelligence/                 Multiverse Intelligence Engine: intent parser, tool orchestration, path narration,
                                  pluggable language models (Ollama; Apple on-device in the app)
    Layout/                       3D force layout, procedural branch geometry, LOD/viewport selection, universe filters
    Privacy/                      field encryption (AES-GCM), CSV/JSON list import, full data export
    Sample/                       FICTIONAL sample universe (every record flagged isSample)
  mvt/                            command-line companion (runs the same engine on your Mac/Linux box)
Tests/MultiverseCoreTests/        unit + integration tests with offline fixtures
App/
  project.yml                     XcodeGen spec → MultiverseTree.xcodeproj (iOS 26, iPhone)
  ExportOptions.plist             IPA export settings
  MultiverseTree/
    App/                          @main app, AppModel (state, layout, research loop)
    Rendering/                    Shaders.metal, CosmicRenderer (HDR + bloom), OrbitCamera, PathRevealAnimator, MTKView host
    Services/                     Keychain, Apple on-device model backend, BGProcessingTask research, performance governor
    Views/                        Universe, People, Profile, Connect (pathfinder), Ask AI, Research, Settings
scripts/                          bootstrap.sh, build_ipa.sh, test_core.sh
docs/ARCHITECTURE.md              design details, data model, AI design, privacy, roadmap
```

## Build & install

### 1. Run the engine tests (Mac or Linux)

```bash
# Linux needs: Swift 5.9+ and libsqlite3-dev
swift test            # or scripts/test_core.sh
```

### 2. Build the iPhone app (Mac required)

Requirements: macOS with **Xcode 26** or later (iOS 26 SDK), an Apple ID (a free one installs on your own device for 7 days; a paid Developer Program membership lasts a year), and an iPhone running iOS 26.

```bash
git clone https://github.com/froelicherzachary80-collab/OMNITREE.git
cd OMNITREE
scripts/bootstrap.sh          # installs XcodeGen with Homebrew if needed, generates App/MultiverseTree.xcodeproj
open App/MultiverseTree.xcodeproj
```

In Xcode:
1. Select the **MultiverseTree** target, then **Signing & Capabilities**, and pick your **Team**. If the bundle ID `com.multiversetree.app` is already taken, change it to something unique.
2. Plug in your iPhone (or pair it over Wi-Fi), select it as the run destination and press **Run** (⌘R).
3. On the iPhone, the first time: **Settings → Privacy & Security → Developer Mode → On**, then trust your developer certificate under **Settings → General → VPN & Device Management**.

### 3. Produce a signed IPA

```bash
TEAM_ID=ABCDE12345 scripts/build_ipa.sh                     # archive + export → build/ipa/MultiverseTree.ipa
xcrun devicectl list devices                                # find your iPhone's identifier
xcrun devicectl device install app --device <UDID> build/ipa/MultiverseTree.ipa
```

`App/ExportOptions.plist` uses the `development` method (installs on registered devices). Switch to `ad-hoc` or `app-store-connect` to distribute another way.

### 4. Optional free companion computer

```bash
swift build -c release
.build/release/mvt multiverse.sqlite sample                       # fictional demo data
.build/release/mvt multiverse.sqlite import-gedcom family.ged
.build/release/mvt multiverse.sqlite ask "How am I connected to McKenna Grace?"
MVT_YOUTUBE_KEY=… .build/release/mvt multiverse.sqlite import-list creators.csv
.build/release/mvt multiverse.sqlite run-jobs                      # long research jobs, uninterrupted
.build/release/mvt multiverse.sqlite backup phone-restore.sqlite   # restore in app: Settings → Your data
```

For free local AI on that computer, install [Ollama](https://ollama.com) and run `ollama pull qwen2.5:7b-instruct` (Apache-2.0). Then point the app (Settings → Multiverse Intelligence) or `MVT_OLLAMA_URL` at `http://<computer-ip>:11434`.

## What works in v0.1

- **Graph database.** SQLite with indexed adjacency. Every relationship requires evidence (source URL or imported-document reference, description, extractor, date) plus a verification status, confidence, last-checked date, provenance and direction. External IDs (Wikidata QIDs, YouTube channel IDs, GEDCOM xrefs, WikiTree, FamilySearch) live in a separate `identity` table. People are matched by ID, never by name. Includes WAL, migrations, online backup and restore, and a response cache.
- **Pathfinder.** Shortest path (bidirectional BFS), strongest documented path (Dijkstra on −log evidence strength), family-only, collaboration-only and mixed paths (Yen K-shortest). Also: multi-person pairwise networks, nearest person of a category, temporal, verification and quality filters, components and communities. Paths only ever use stored edges. When only unverified candidate edges link two people, the result is labelled *Possible connection — research required*.
- **World Family Tree Engine.** GEDCOM 5.5.1 import (CONC/CONT, adoption via PEDI, events, FamilySearch and WikiTree IDs) and export. Lowest-common-ancestor search, cousin degree and removal, and half relationships. Removing an import undoes it. Possibly-living relatives are private and excluded from research by default.
- **Merge engine.** Scores matches on name, dates, places, parents, spouses and identifiers. Different IDs in the same scheme block a merge, and a matching name alone is capped below the proposal threshold. Merges happen only after user approval. The original record is kept in `merge_history`.
- **Research.** Wikidata person data, family and teacher statements (with qualifiers), film and TV co-credit networks, and group members. Wikipedia summaries supply biographies. The YouTube Data API (your free key) provides channel metadata and upload scans. Mentions become `channelMention` and title "ft." becomes `videoCollaboration`, always stored as *candidates* for review and never as friendship. Requests are rate-limited, cached for offline use, deduplicated, retried with backoff, resumable via cursor, schedulable for refresh, and logged.
- **Multiverse Intelligence Engine.** Ask Multiverse AI parses each request into a tool call and runs the real graph and research functions. It shows the tool trace, sources inspected, discoveries, rejected or uncertain claims, graph changes and open questions. People with the same name trigger a disambiguation prompt. Optional language models (Apple's on-device model, or Ollama on your own computer) only map unusual phrasings to the tool schema and rephrase grounded results. Any name the model returns that is not in your request is rejected.
- **Universe renderer (Metal).** HDR pass with a nebula background, starfield and drifting energy motes, and procedural organic branch ribbons with tendrils, white cores, coloured glow by relationship category, ambient electrical pulses and dashed candidate edges. Nodes are instanced billboards with depth-of-field softening. Bloom is MPS Gaussian, followed by ACES tonemapping and a vignette. There are four quality tiers, with automatic downgrade on frame time, thermal state, Low Power Mode or graph size. LOD keeps highlighted nodes and their neighbourhood, picks the remaining nodes by degree and camera distance up to the budget, and draws the rest as cluster nebulae.
- **Branch reveal.** The sequence darkens the universe, highlights the start node, pulses down each hop, reveals each person, merges alternative paths, zooms out and opens the evidence panel. It supports pause, replay, camera rotation and inspecting any hop. Newly researched relationships grow from node to node.
- **App screens.** Eight combinable universe modes and filters (relationship type, category, date, country, source quality, verification, community, graph distance). A record-backed profile with all requested sections and buttons. Connect (pathfinder UI), Ask AI, Research (jobs, approval queue, merge review, GEDCOM/CSV/JSON import, source-availability dashboard) and Settings (quality, keys, local AI, export, backup and restore, sample data).
- **Privacy.** Private notes are AES-256-GCM encrypted, with the key in the device-only Keychain. The store refuses to write private data when no cipher is configured. Private people are hidden from research and from public views, and from GEDCOM export by default. You can delete people, remove an import, mark a profile private, exclude a person from research, review and approve uncertain relationships and merges, and export everything as JSON.

## Status — what remains

| Area | State |
|---|---|
| Core engine + CLI | Built and tested on Linux (Swift 6.0.3): 54 tests pass |
| iOS app target | Written in full but **not yet compiled** (written without Xcode). Expect small fixes on first build; the `ios-app` CI job compiles it on a macOS runner |
| Signing / IPA | Needs your Apple Team ID on a Mac (steps above). An IPA can't be produced or signed without Xcode and an Apple account |
| Live research | Wikidata, Wikipedia and YouTube calls are covered by offline fixture tests. Live network runs were not possible here (outbound access was restricted) |
| App icon | Placeholder asset catalog entry; add a 1024×1024 image |
| Later roadmap items | Transcript and video analysis, OpenAlex/Open Library/Internet Archive connectors, WikiTree API, DNA import and the timeline agent are planned (see `docs/ARCHITECTURE.md` § Roadmap). Their dashboard entries say "planned"; none of them is faked |

## Sample data

**Settings → Load fictional sample universe** adds 19 invented people across a family, a Minecraft SMP, a film and an observatory. Every record says "sample", is excluded from research and can be removed in one tap. No real person's relationships are included as sample data. Real people come only from research, with sources.
