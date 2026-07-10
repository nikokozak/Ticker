# R3 — Semantic Retrieval Plan (2026-07-10)

Supersedes the MLX-based R3 sketch in `PRODUCTION_READINESS_PLAN.md` (Task 3.1 and the
"embedding model download" UX note). MLX was removed from the build graph in the 2026-07
audit and does not come back in this phase. This document is written for governed Codex
execution: one session, one phase per round, constants measured by the harness — never
asserted here (the P4 FNV lesson).

## The problem, precisely

BM25 over `source_chunks` requires lexical overlap. Live-documented misses: lease-style
paraphrase questions scoring below the per-token cutoff against legalese; conceptual
questions that dodge a book's vocabulary. H1.1's single-source floor mitigates one shape
(single-source streams) heuristically. Semantic similarity is the real fix — and it is
also a classic complaint generator when built wrong (wrong chunks retrieved confidently,
downloads users didn't ask for, indexing that never finishes, memory bloat).

## Design tenets (the complaint-surface contract)

1. **BM25 is the floor; embeddings only add.** Every failure in the semantic path —
   missing asset, missing vector, timeout, model error, memory pressure — degrades to
   exactly today's behavior, silently. No error, status, or dialog from the semantic
   path may ever reach the user.
2. **Nothing ships without the eval gate.** If hybrid retrieval does not measurably beat
   BM25 on the paraphrase class with zero regression on the negative class, R3 ends and
   BM25 stays. Stopping is a first-class outcome.
3. **Zero new user surface.** No settings row, no consent dialog, no download progress,
   no new index states, no UI change of any kind. The scope chip (Auto/All/None),
   provenance strip, citations, and passthrough mode behave identically. R3 changes
   *which chunks are picked* — nothing else.
4. **Embeddings are a disposable cache.** Rebuildable from `source_chunks` at any time;
   destructive rebuild is always safe (pre-release posture). They are never the source
   of truth for anything.
5. **Shadow before live.** The hybrid picker runs in log-only mode on real usage before
   it influences a single answer.
6. **Platform first.** Candidate ladder: `NLContextualEmbedding` (OS-managed, zero
   dependency) → Core ML-converted small embedding model bundled in the app (no
   download, no dependency) → stop. MLX is not a candidate.

## Locked decisions

| # | Decision |
|---|---|
| D1 | Retrieval fusion lives inside `RetrievalService.retrieve` — `assembleSourceContext` remains the one decision point and its interface does not change. |
| D2 | Vector search is brute-force cosine over per-stream chunks in memory. No vector DB, no sqlite extension. (Forth = 209 chunks ≈ 0.4 MB of vectors; brute force is milliseconds at 100× that scale.) |
| D3 | Fusion is Reciprocal Rank Fusion over (BM25-passing candidates ∪ cosine-floor-passing candidates), then top-k. No learned weights, no tuned linear blends. |
| D4 | The cosine floor and the pass/fail margins are **computed by the harness during R3.1**, recorded in the harness config, and never hand-edited afterward. |
| D5 | Schema: one new table `chunk_embeddings(chunk_id PK→source_chunks, model_id TEXT, dims INT, vector BLOB float32)` via append-only migration (next free vN). `model_id` mismatch ⇒ row treated as missing and lazily recomputed. |
| D6 | Source readiness semantics unchanged: a source is "indexed" when FTS is ready (today's rule). Embeddings fill in behind, lazily; chunks without vectors simply don't participate in the semantic leg. |
| D7 | Query embedding has a hard time budget (measured in R3.1, order ~100ms). Budget blown ⇒ semantic leg skipped for that query, logged, BM25 proceeds. |
| D8 | The negative-class guarantee (unrelated queries retrieve nothing) is a release ritual: the golden eval runs before any release that touches retrieval. CI carries only the hermetic fusion tests (canned vectors); the model-dependent eval is a local `tickerctl` lane. |

## Architecture (what actually gets built)

```
IngestService (existing actor)
  └─ after FTS chunk insert → EmbeddingIndexer.enqueue(chunkIds)   [non-blocking]
EmbeddingProvider (protocol, ~3 methods: prepare(), embed([String]) -> [[Float]], modelId)
  └─ one live implementation chosen in R3.1
RetrievalService.retrieve (existing, 201 lines)
  ├─ BM25 leg: unchanged (cutoffs, caps, single-source floor)
  ├─ semantic leg: embed(query) within budget → cosine vs stream vectors → floor filter
  └─ RRF fuse → top-k 8 → existing manifest/passthrough/threshold logic unchanged
chunk_embeddings (vN migration, cache table)
tools/retrieval-eval/ (golden set JSON + scorer; tickerctl eval-retrieval lane)
```

Estimated new/changed code: one provider file, one indexer extension on IngestService,
~60 lines in RetrievalService, one migration, tests. No bridge changes, no contract
changes, no web changes.

## Failure-mode table (every row ends in "user sees nothing")

| Mode | Behavior |
|---|---|
| Embedding assets not yet available (first run) | Semantic leg absent; BM25-only; provider retries `prepare()` lazily, never blocks |
| Query embed timeout/error | Semantic leg skipped for that query; DebugLog only |
| Chunk lacks a vector (backfill pending) | Chunk competes in BM25 leg only |
| `model_id` mismatch after provider update | Vector treated as missing; lazy recompute |
| Memory pressure / model resident too long | Provider unloads after idle; reloads on demand; a reload failure = "assets not available" row |
| Migration failure | Standard migration failure path (backup hard gate already enforced) |
| Unrelated query (pasta test) | Cosine floor + BM25 cutoff both gate ⇒ "No source context passed threshold", exactly as today |

## Phases

### R3.0 — Eval harness + golden set + baseline (no product code)
- `tools/retrieval-eval/golden.json`: ~30–40 cases, three classes:
  **lexical** (BM25 already wins — regression guard), **paraphrase/conceptual** (the
  target class; includes the live-documented lease-style and vocabulary-dodging cases),
  **negative** (pasta-class; expected result: nothing retrieved).
  Each case: query, inline chunk corpus (text + page metadata, extracted from real
  sources — hermetic, no PDFs, no user DB), expected chunk ids (or empty).
  Governor drafts the set from the real corpora; Niko sanity-checks (~15 min).
- Scorer: builds an in-memory DB, runs the real `RetrievalService` code, reports
  recall@8 per class + false-retrieval rate on negatives. Runs via
  `./tickerctl.sh eval-retrieval`.
- Deliverable: committed baseline numbers for BM25-only. **Gate for R3.1:** harness
  runs deterministically and the baseline confirms the paraphrase gap is real.

### R3.1 — Provider bake-off (spike; throwaway branch)
- `EmbeddingProvider` protocol + two candidates:
  (a) `NLContextualEmbedding` (mean-pooled sentence vectors, OS asset management);
  (b) a Core ML-converted MiniLM/bge-small-class model, bundled (~25–45 MB, no
  download). Build (b) only if (a) fails the gate.
- Extend the scorer: hybrid = D3 fusion; sweep the cosine floor on the harness to find
  the operating point (maximize paraphrase recall subject to zero negative regressions);
  record floor + margins into the harness config (D4).
- Measure: per-class recall, query-embed latency (p50/p95), model memory, first-run
  asset behavior.
- **Ship/stop gate:** paraphrase recall improves by a clear margin (target ≥ +20 points)
  AND negatives unchanged AND p95 query embed within budget on Niko's machine. Neither
  candidate passes ⇒ R3 stops; doc records the numbers and BM25 remains.

### R3.2 — Product integration (behind shadow flag)
- Migration vN: `chunk_embeddings` per D5.
- `EmbeddingIndexer` on IngestService: embed after FTS commit, batched, throttled;
  lazy backfill for existing sources piggybacking the existing stream-open backfill
  path. Terminal-status semantics untouched (D6).
- Semantic leg + fusion in `RetrievalService` behind an internal mode:
  `off | shadow | on` (UserDefaults, no UI), default **shadow**.
- Tests: hermetic fusion/floor tests with canned vectors (CI); indexer failure-path
  tests (embed error ⇒ FTS untouched, no status change); migration test.
- Gates: the standard six + `eval-retrieval` run locally.

### R3.3 — Shadow → live
- Shadow mode logs, per real query: BM25 pick set vs hybrid pick set, divergence count,
  and whether the semantic leg ran (DebugLog + a counter in the support bundle).
- Niko uses the app normally for a few days; governor reviews divergence logs — looking
  specifically for *bad adds* (semantic chunks that would have polluted context).
- Flip default to `on`; keep the flag one release as a kill switch; then delete it.
- Release ritual per D8 begins here.

### R3.4 — Follow-ons (explicitly not R3)
- ⌘K semantic stream search (separate table, separate plan).
- Re-examine H1.1's single-source floor — likely subsumed by the semantic leg; remove
  only with golden-set proof.
- Marginalia's possible return as retrieval-grounded source pointers (per IA_CORE_PLAN
  P7 retirement note).

## Execution protocol

Governed Codex per the established rules: one session for R3.0–R3.3, resumed by explicit
id, compacted when heavy; Sol medium default, Sol high only if a phase turns
design-ambiguous; no sub-agents; ponytail in every prompt; all six gates per round plus
`eval-retrieval` where it exists. The golden set and all thresholds live in
`tools/retrieval-eval/` — code reviews reject any hand-edited constant that the harness
should have produced.
