# Caption Accuracy — Book & Series Context Vocabulary (iOS)

**Date:** 2026-07-22
**Status:** Design approved, pending implementation plan
**Platform:** iOS 26+ only (extends the read-while-listening captions feature)
**Builds on:** `docs/superpowers/specs/2026-07-22-read-while-listening-captions-design.md`

## Goal

Improve on-device caption transcription accuracy — especially the proper nouns
ASR mangles (character names, invented places) — by biasing the recognizer with
a vocabulary built from the book's own metadata and, when the book is part of a
series, the other books in that series.

## Why this works

iOS 26's `SpeechAnalyzer` accepts an `AnalysisContext` whose `contextualStrings`
(`[AnalysisContext.ContextualStringsTag: [String]]`) biases the transcription
engine toward supplied words/phrases even when they fall outside the system
vocabulary. There is no custom-pronunciation-dictionary API, but term biasing is
exactly the lever we need: feed it the story's names and the recognizer favors
them over phonetically-similar generic words.

**Honest impact bound:** biasing *nudges*; it does not teach the model a name it
has no phonetic path to, and blurbs don't name every character. Expect
meaningful improvement on the main cast and principal places, not perfection.

## Scope decisions

Settled during brainstorming; each rules out a different product.

| Decision | Chosen | Rejected |
|---|---|---|
| Vocabulary source | Current book **+ series siblings** | Current book only; structured fields only |
| When gathered | **At download time**, stored beside the book | At enable-time best-effort; enable-time + cache |
| Extraction | **Apple `NLTagger` NER + a Title-Case heuristic**, unioned, + structured fields | NER alone; heuristic alone; raw blurb text; Core ML fine-tuned NER |

> **Extraction correction (during implementation):** `NLTagger` NER is trained on
> real-world entities and reliably skips or misclassifies **invented** fantasy/
> sci-fi proper nouns — the exact vocabulary this feature targets. Fine-tuning a
> Core ML NER model is disproportionate (per-genre training data, model pipeline,
> app size) for a biasing feature. The blurb itself is the candidate name list:
> fantasy/sci-fi blurbs capitalize their invented names. So extraction **unions**
> two on-device passes — NER (real names/places/orgs) **and** a Title-Case
> proper-noun heuristic (consecutive capitalized tokens, leading article stripped,
> single common/function words dropped) — catching both real and invented names.
| Existing downloads | **New downloads only (v1)** — no backfill | One-time backfill; rebuild-on-enable |

## Verified constraints

- `AnalysisContext.contextualStrings` is `[ContextualStringsTag: [String]] { get set }`
  (Apple docs, iOS 26). Set the tag→terms map on the context and pass it to the
  `SpeechAnalyzer`. Exact `ContextualStringsTag` construction to be pinned in the
  plan against the SDK.
- Client `Metadata` (Realm) carries `title`, `subtitle`, `authorName`,
  `narrators`/`narratorName`, `genres`, `desc` (blurb), `seriesName`. It does
  **not** persist a series *id*; series-sibling resolution happens web-side where
  the full server library item (with `series[].id`) and the authenticated API are
  available (the app already browses series).
- `NLTagger` with the `.nameType` scheme (`NaturalLanguage`, on-device, iOS 12+)
  classifies tokens as `.personalName` / `.placeName` / `.organizationName`.
- The download flow is native (`AbsDownloader`) with a finalize step; web is
  notified of download completion, which is the trigger for context building.
- Captions store their per-item data in the item download folder
  (`captions.json`) so it is evicted with the download; `context.json` follows
  the same convention.

## Architecture

A web/native split along each layer's strength. Web gathers data (it has the
metadata, series ids, and authenticated API); native does NER, storage, and ASR
consumption (NLTagger and SpeechAnalyzer are native, on-device).

### 1. Web — corpus gathering (existing web layer)

On download completion, the web layer:
- Collects the **current book's** fields (title, subtitle, author(s), narrator(s),
  series name) and description.
- If the book is in a series, fetches the **series siblings** via the existing
  server API and collects each sibling's title / author / description.
- Calls `AbsTranscriber.buildContext({ libraryItemId, fields, bookBlurb, seriesBlurbs })`
  where `fields` is the current book's structured names (author, narrator, series,
  title), `bookBlurb` is the current book's description, and `seriesBlurbs` is an
  array of the siblings' descriptions (empty when not in a series / fetch failed).

Series fetch is best-effort: failure or offline yields `seriesBlurbs: []`.

### 2. `CaptionContextBuilder.swift` (new, native) — NER + vocabulary policy

Pure-ish, unit-testable. Interface: given the current book's `fields: [String]`,
its `bookBlurb: String`, and `seriesBlurbs: [String]`, return an ordered, deduped,
capped `[String]` of biasing terms. Provenance is explicit from the separate
parameters — no guessing.
- Runs `NLTagger(.nameType)` over `bookBlurb` and each `seriesBlurbs` entry,
  keeping tokens tagged `.personalName` / `.placeName` / `.organizationName`.
- Merges the structured `fields`.
- Dedupes case-insensitively (preserving first-seen surface form).
- Orders by **priority**: current-book names (from `bookBlurb`) → series-sibling
  names (from `seriesBlurbs`) → structured `fields`.
- Caps the list (start ~100; tunable) so the highest-priority names survive.
- Multi-word names kept intact.

### 3. `CaptionContextStore.swift` (new, native) — persistence

Mirrors `CaptionStore`: reads/writes/evicts `context.json` in the item download
folder. Payload: schema version + the ordered term list (+ minimal provenance
counts for diagnostics). `load()` never throws — returns `[]` on missing/corrupt.

### 4. `AbsTranscriber.swift` (modify) — plugin surface

- New method `buildContext({ libraryItemId, fields, corpus })`: resolves the
  item's download folder, runs `CaptionContextBuilder`, writes via
  `CaptionContextStore`. Returns a small summary (term count). Idempotent
  (overwrites).
- `enable()`: after building the scheduler context, load the item's stored terms
  via `CaptionContextStore` and pass them into the engine (see 5).

### 5. `SpeechTranscriptionEngine.swift` (modify) — consumption

- Gains an optional `contextualStrings: [String]` (engine init or per-transcribe).
- In `run()`, when non-empty, set `analysisContext.contextualStrings[tag] = terms`
  and pass that `AnalysisContext` into the `SpeechAnalyzer` (init or `setContext`).
- Empty/absent → no context, identical to current behavior.

### 6. `plugins/capacitor/AbsTranscriber.js` + web trigger (modify)

- Add `buildContext` to the JS wrapper.
- A web handler on download-complete assembles the corpus (current + series
  siblings via the existing API) and calls `buildContext`. New downloads only.

## Data flow

Download completes → web gathers corpus (current book fields+blurb; series
siblings' fields+blurbs, best-effort) → `AbsTranscriber.buildContext` → native
`CaptionContextBuilder` (NER + fields → dedupe → priority → cap) →
`CaptionContextStore` writes `context.json` in the item folder.

Later: tap CC → `enable` loads `context.json` terms → engine attaches them as
`AnalysisContext.contextualStrings` on every transcription window → recognizer
biased toward the story's names.

## Error handling & degradation

All silent and feature-preserving:

| Condition | Behavior |
|---|---|
| `context.json` absent (older download, build failed, backfill out of scope) | Engine runs with no bias — current behavior |
| Book not in a series | Current-book context only |
| Offline / series fetch fails at download | Build from current-book fields + blurb; siblings skipped |
| NER yields nothing | Fall back to structured fields |
| `buildContext` fails | Log via `AbsLogger`; captions still work without bias |

Context building must never block or fail a download, and never disturb playback.

## Testing

- **`CaptionContextBuilder` unit tests (native)** — where correctness lives:
  NER extraction over a sample blurb (known person/place names in → expected terms
  out), case-insensitive dedupe, priority ordering (current > siblings > fields),
  cap enforcement, multi-word names preserved, empty-corpus → fields-only.
- **`CaptionContextStore` unit tests** — round-trip, missing/corrupt → `[]`, evict.
- **Engine wiring** — device-verified: does attaching `contextualStrings` actually
  improve accuracy on a fantasy/sci-fi book with names the base model mangles
  (the whole point). Confirm no regression when the term list is empty.
- All existing caption unit tests remain green; the change is additive (one
  optional engine parameter, new isolated units).

## Out of scope (v1)

- Backfilling context for already-downloaded books.
- Rebuilding context when metadata changes server-side.
- Podcasts.
- Any custom-pronunciation / phonetic-spelling mechanism (no such API).
- Tuning the cap beyond a sensible default (revisit after device testing).
