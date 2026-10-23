# Multiverse Tree — Architecture

## Layers

```
┌──────────────────────────── iOS app (App/) ─────────────────────────────┐
│ SwiftUI views ── AppModel (@Observable, MainActor) ── CosmicRenderer     │
│                     │  layout / scene build off-main      (Metal + MPS)  │
├─────────────────────┼────────────────────────────────────────────────────┤
│              MultiverseCore (Swift package, platform-independent)         │
│  Intelligence ─► Research agents ─► Connectors ─► ResearchHTTP (cache)    │
│        │                │                                                 │
│        ▼                ▼                                                 │
│   PathFinder / Kinship ◄── GraphIndex (CSR) ◄── GraphStore ◄── SQLite     │
│   Layout / BranchGeometry / ViewportSelector                              │
└───────────────────────────────────────────────────────────────────────────┘
```

The core runs anywhere Swift runs: on the iPhone, in the `mvt` companion CLI and in Linux CI.

## Data model (SQLite, `Schema.v1`)

| Table | Purpose |
|---|---|
| `person` | persistent UUID, names, partial dates (ISO + raw + qualifier + year for indexing), places, occupation, bio, privacy flags, sample flag, origin, encrypted `private_blob` |
| `person_category`, `person_alias` | multi-category membership and aliases (indexed for search) |
| `identity` | external IDs `(scheme, value)` with UNIQUE; the only basis for identity resolution |
| `platform_account` | YouTube/Twitch/… accounts |
| `organization`, `community`, `community_member` | SMPs, creator groups, institutions |
| `media_project`, `media_credit` | films, series, videos and credits |
| `source` | citable sources with reliability prior and licence; URL-deduplicated |
| `relationship` | graph edges: type, category, direction, inferred flag, verification, confidence, dates, last_checked, provenance, context; `UNIQUE(from,to,type,context)`; undirected edges stored with `from < to`; indexes on `(from_id,type)` and `(to_id,type)` |
| `relationship_evidence` | ≥1 per relationship (enforced in `GraphStore.addRelationship`) |
| `family_event` | birth/death/marriage/… timeline |
| `research_job`, `research_log` | persistent queue with cursor, attempts, backoff schedule, refresh interval, dedup key; audit log |
| `source_cache` | HTTP response cache for offline mode and rate limits |
| `graph_snapshot`, `node_layout` | snapshots and persisted 3D layout |
| `merge_proposal`, `merge_history` | review queue and preserved original records |
| `user_preference` | settings |

### Integrity rules
- **No evidence, no edge.** A relationship cannot be stored without evidence.
- **Verification never silently downgrades.** A user rejection is never overridden by automated research, and rejected edges never enter the traversal index.
- **Weak signals stay weak.** Mentions and appearances are separate types (`channelMention`, `featuredInVideo`, …). They are flagged `isWeakAssociation` and can never become friendship or kinship.
- **Only established edges count as fact.** `verified`, `sourced` and `userAsserted` edges are shown as established. `candidate` edges appear as "Possible connection — research required".

## Graph engine

`GraphIndex` is a compressed-sparse-row adjacency built by streaming SQLite rows. Each edge in memory is about 80 bytes, so a few million edges fit on an iPhone. `PathFinder` provides:

- bidirectional BFS (shortest by hops), single-source BFS distances
- Dijkstra with `cost = −ln(confidence × best source reliability) + 0.01` (strongest chain)
- Yen's K-shortest loopless paths (alternatives / mixed paths)
- `connectionReport` → shortest, strongest, family-only, collaboration-only, mixed, and candidate-only "possible" path
- `multiConnection` → pairwise paths + union "shared network"
- `nearest(where:)` → closest person of a category
- union-find components and weighted label-propagation communities (used to seed the layout into galaxies)

`KinshipCalculator` walks documented `parent` / `adoptiveParent` edges upward, finds the lowest common ancestors, and names the relationship ("first cousin once removed", "half-sibling", "great-aunt/uncle", …).

## Multiverse Intelligence Engine (MIE)

The agents named in the spec map onto real modules:

| Agent | Implementation |
|---|---|
| Source Discovery | `SourceRegistry`, `WikidataConnector.search` |
| Public Profile / Celebrity / Historical Research | `WikidataResearchAgent.importPerson`, `importFilmography`, `WikipediaConnector` |
| YouTube Research | `YouTubeConnector`, `YouTubeResearchAgent` |
| Genealogy Research | `GEDCOMImporter`, Wikidata family statements |
| Identity Resolution | `IdentityResolver` (external-ID only) |
| Relationship Extraction | statement→edge mapping, `YouTubeConnector.extractCandidates` |
| Source Verification | `SourceVerificationAgent` (≥2 independent strong source kinds → verified; user approval) |
| Graph Construction | `GraphStore.addRelationship` (dedup, evidence merge, verification precedence) |
| Shortest Path | `PathFinder` |
| Conversational Research | `IntentParser` + `MultiverseIntelligence` |
| Duplicate Detection | `MergeEngine` |
| Timeline Reconstruction | `family_event` + profile timeline (agent planned for v0.7) |

**Language models.** MIE is tool-first. The rule parser covers the documented request types. When it fails and a model is configured, the model must reply with one JSON tool call from a fixed schema. Every name in that call must appear literally in the user's text, otherwise the call is rejected. Models may rephrase final answers only from the facts passed to them, and the cited path breakdown is always shown alongside. Backends:

- `OnDeviceLanguageModel`: Apple's on-device model (FoundationModels, iOS 26 with Apple Intelligence). Free and offline.
- `OllamaLanguageModel`: any open-weight model on a computer you own (e.g. Qwen2.5-7B-Instruct, Apache-2.0).

There is no paid API and no scripted answer path. If nothing can be computed, MIE says so.

## Rendering

`UniverseSceneBuilder` (core) turns the graph, layout and filter into GPU-ready buffers:

- `BranchVertex` (4×float4): centre-line position + t, tangent + side, colour, width/edge-slot/kind/established. Ribbons are expanded camera-facing in the vertex shader, and all branches go out in **one indexed draw call**.
- `NodeInstance` (3×float4): instanced billboards.
- Per-edge state buffer (`float4`: highlight, growth, pulse start, dim). The renderer drives reveal, growth and selection animation through this buffer without touching geometry.

`CosmicRenderer` frame: background nebula → stars and motes → cluster nebulae → branches (additive) → nodes (additive) into an RGBA16F HDR target → half-resolution bright pass → `MPSImageGaussianBlur` → composite with ACES tonemap and vignette. Per-frame buffers are triple-buffered behind a semaphore.

**Scale.** `ViewportSelector` keeps a per-quality node budget (1.5k–15k) and edge budget (4k–45k). Highlighted nodes and their neighbours always render, then the highest-scoring nodes by degree ÷ camera distance. Everything else is aggregated per community into cluster nebulae (progressive disclosure). Layout is O(n) per iteration (spatial hashing), runs off the main thread, and is persisted. New nodes settle around pinned existing ones.

**Quality tiers** (`RenderQuality`): segments per branch, tendrils, particles, bloom sigma, depth of field and FPS target. `PerformanceGovernor` steps down when frames run 30% over budget, the device is in a serious or critical thermal state, Low Power Mode is on, or the graph is very large.

## Research scheduling on iOS

- Jobs run while the app is in the foreground. `BGProcessingTask` gives short, OS-scheduled windows and stops itself before iOS's deadline. Interrupted jobs are re-queued and resume from their cursor.
- iOS does **not** allow indefinite background work. For large crawls (e.g. 100 channels), run `mvt … run-jobs` on your own computer and restore the database on the phone.
- Duplicate jobs are refused (`dedup_key`). Transient failures back off exponentially and honour `Retry-After`. Offline mode pauses network jobs, and a missing YouTube key pauses YouTube jobs rather than failing them.

## Privacy & security

- Private fields are AES-256-GCM encrypted (CryptoKit). The key is in the Keychain (`AfterFirstUnlockThisDeviceOnly`) and the database file uses iOS file protection. Without a cipher, the store refuses to persist private data rather than writing it in plaintext.
- GEDCOM people who may be living, plus friends and family categories, are private and `excludeFromResearch` by default. Research agents check the flag before any request. Private people are excluded from `includePrivate: false` graph loads, searches and exports.
- User controls: delete a person, remove a GEDCOM import, toggle private, exclude from research, approve or reject candidates, approve or reject merges, export all data (JSON or GEDCOM), back up and restore, clear the cache, remove sample data.
- Living people: profile text distinguishes researched public facts (Wikidata/Wikipedia/YouTube origin) from user-provided private information.
- DNA: not imported in v0.1. When added (v0.4+), it will only support matching within the user's own authorised data and never assert specific ancestors or celebrity kinship.

## Free sources & terms

Every connector uses a documented, free, public API within its terms: Wikidata (CC0, User-Agent identified, ~1 SPARQL query/s), Wikipedia REST (CC BY-SA, attribution shown), and YouTube Data API v3 (your key, 10k units/day; channels and playlistItems only, no `search` in automated jobs). There is no scraping and no bypassing of authentication or paywalls. FamilySearch and WikiTree are import/reference only until an authorised integration exists.

## Roadmap

| Version | Scope | Status |
|---|---|---|
| 0.1 | iOS shell, cosmic renderer, local graph DB, GEDCOM import/export, Wikidata research, shortest-path engine | **this release** (+ early pieces of 0.2–0.4) |
| 0.2 | YouTube discovery, channel imports, creator communities, source evidence | connector, agent, candidates and list import done; community rosters next |
| 0.3 | Celebrity / entertainment network, better identity resolution | Wikidata co-credits done; cross-source corroboration next |
| 0.4 | Genealogy research, common ancestors, duplicate merging | LCA, kinship and merge engine done; WikiTree API + DNA (own-data only) next |
| 0.5 | Local AI research agents, video analysis | authorised transcripts + on-device speech (Speech framework / whisper.cpp) for user-provided media |
| 0.6 | Multi-person analysis, advanced path visualisation | pairwise networks done; Steiner-tree compaction next |
| 0.7 | Historical research, timeline reconstruction, community clustering | OpenAlex, Open Library, Internet Archive connectors |
| 0.8 | Large-graph optimisation, scheduling, offline caching | GPU-side culling, mmap'd index snapshots |
| 0.9 | Advanced cinematic rendering & navigation | volumetric fog, GPU particles along branches, path-camera splines |
| 1.0 | Complete unified app, documented testing, IPA workflow | — |
