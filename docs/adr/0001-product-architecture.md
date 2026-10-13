# ADR 0001 — Product Architecture (OpenMind Rust whiteboard)

Date: 2026-10-13
Status: accepted
Baseline: rustc 1.98.0, macOS 27.0.1, arm64 (Apple Silicon), eframe/egui 0.36.2

## Context

The implementation plan (`instructions/macOS_whiteboard_implementation_plan.md`)
asks for a Rust-native, offline-first macOS whiteboard reusing the
`openmind-vector` (VectorCraft-derived) stack where it fits, with GazBoard as a
behavior checklist — not as a runtime (GazBoard is Electron/JS; we do not
introduce Electron).

Current branch (`openmind-rust`) already has:

- `rust/crates/board` — Swift-compatible `.vsom` model (`Board`, `CanvasItem`,
  `VsomDocument`, reference-date `Date`s, base64 `Data`), viewport math,
  sheet presets.
- `rust/crates/ink` — pressure-aware inking on `vectorcraft-geom` +
  `vectorcraft-brush::track` (smooth → resample → frame → outline), Swift
  `StrokeCodec [[x,y]]` compat.
- `rust/crates/canvas` — scene model (`CanvasDoc`: stable `ItemId`, z-order,
  lock/group, selection/marquee, snapshot undo, `.vsom` mapping with foreign
  record carry-along).
- `rust/crates/app` — `openmind` eframe desktop (select/pen/highlighter/eraser/
  hand, shapes, sticky/text, images, `.vsom` save/open).
- Sibling `../../openmind-vector` provides `geom`, `brush`, `color`, `doc`,
  `render` by path (never copied).

Gaps vs. the plan: no stable object IDs in the persisted format, no
command layer, no spatial index/culling, no asset service (images embed bytes
in items), no rich-text model, no audio/video/YouTube, no autosave/recovery
journal, no package format, no export suite, no templates/gallery, no
performance budgets.

## Decision

### 1. What is reused unchanged

- `vectorcraft-geom` (Bezier paths, rects, hit-testing primitives), `brush`
  (track frames for inking), `color`, `doc`, `render` (headless PNG smoke test
  path) — by path dependency, no vendoring.
- `board` `.vsom` wire format stays byte-compatible with the Swift app
  (field names, base64, reference dates). We only *add* optional fields.
- `ink` pipeline stays as-is; eraser hit-testing and `StrokeCodec` compat are
  the reference for pen/highlighter.
- `canvas` selection/group/arrange semantics (ported from Swift
  `CanvasView`/`CanvasGrouping`) stay; we extend content types, not rewrite.

### 2. What is extended in document model and UI

- `board`: adds `StableBoard` (board ID, schema version, background, ordered
  objects with stable IDs in world coords, asset manifest, viewport, app
  metadata separate from content), validation, migrations (v1→v2, unknown
  kinds preserved as opaque), `.canvaspkg/` package format
  (`manifest.json`/`document.json`/`assets/<sha256>`/`thumbnails/`), atomic
  write + path-traversal guards.
- `canvas`: adds `Connector`, `Table`, `RichText`, `ImageRef`, `AudioRef`,
  `VideoRef`, `YoutubeRef`, `PdfRef` content (lightweight refs, not decoded
  bytes), resize/rotate transforms, spatial grid index + viewport culling,
  templates, performance fixtures.
- `app` (eframe): keeps the existing egui canvas renderer (no second GPU
  renderer, no HTML canvas). Adds toolbar actions (record voice, audio/video/
  YouTube cards, tables, connectors, templates, gallery, export), shortcuts,
  autosave status, accessibility labels, reduced-motion respect. eframe is kept
  because a documented prototype proving it cannot host a macOS feature does
  not exist; YouTube uses click-to-load + external browser fallback so no
  WebKit embedding is required in the canvas loop.

### 3. New crates/modules

```text
rust/crates/
  board/        extended (ids, assets, manifest, package, migrate, validate)
  canvas/       extended (spatial, transforms, connectors/tables/rich, templates)
  text/         NEW: structured rich-text document model + sanitize + layout bridge
  media/        NEW: AssetStore trait + fs store, import pipeline, YouTube URLs, links
  media-audio/  NEW: AudioCapture / AudioPlayer traits, WAV impl, waveform peaks
  media-video/  NEW: format matrix, metadata/poster traits, player lifecycle
  engine/       NEW: command layer (Add/Delete/Transform/RichText/Asset/Layer),
                undo grouping, dirty/autosave hooks
  export/       NEW: PNG/SVG/PDF/native/manifest exporters (headless, no UI thread I/O)
  app/          extended (autosave, recovery, gallery, media cards, shortcuts)
  ink/          unchanged core
```

A single `media` crate with modules was considered; split into
`media`/`media-audio`/`media-video` now because audio capture vs. video
playback have disjoint dependencies/licensing and the plan explicitly calls
out replaceable backends. `engine` is separate from `canvas` so UI code never
holds a borrowed mutable service across frames.

### 4. Audio/video engine decision + licensing

- Capture: `cpal` evaluated for cross-platform mic input; default build uses a
  narrow `AudioCapture` trait with a pure-Rust WAV writer + mock device so the
  workspace builds without system audio deps. A `cpal` adapter can be added
  behind a cargo feature after device/format prototyping on Apple Silicon +
  Intel. `NSMicrophoneUsageDescription` is always present; permission is asked
  only on Record.
- Decode/playback: `symphonia` evaluated for decode; default build uses the
  same trait boundary with WAV/PCM support + AVFoundation noted as the
  preferred macOS playback path for system codecs (narrow bridge, isolated
  from board model). No FFmpeg by default: broad codecs but LGPL/GPL,
  packaging size, and security-update burden require a separate review before
  shipping. No custom decoder.
- Video: same trait isolation. AVFoundation bridge preferred on macOS;
  FFmpeg/GStreamer only if the format matrix requires them. Canvas shows a
  poster frame; live decode runs only in a dedicated overlay, never per-card.
- Codecs/fonts/icons licenses are audited before distribution (see §7).

All traits keep timing/buffering outside the canvas render loop; one active
audio player by default; board close stops playback.

### 5. YouTube: embedded WebKit vs. external browser

External browser fallback + click-to-load card. Rationale: hosting a live
WebKit view per card breaks the performance budget (memory, process count)
and complicates sandboxing; YouTube terms/branding require the documented
embed/player mechanism, no stream scraping, no ad/DRM bypass. The canvas card
stores only `videoId` + thumbnail URL; Play opens `https://www.youtube.com/
embed/VIDEO_ID` in the system browser (or a single WebKit view if a future
prototype proves it safe). Blocked/private/region-locked videos show
"Open in YouTube". No credentials in board metadata.

### 6. Media storage + migration

- In-memory objects store `AssetRef { hash, mime, bytes, … }` (hash =
  hex SHA-256, streamed copy, dedup by content). No decoded frames/bitmaps/PCM
  in frequently-mutated state. Waveforms store compact peak arrays versioned
  by algorithm, cached by hash.
- `.vsom` (single JSON, Swift-compatible) stays the interchange format;
  embedded `imageData`/`audioData`/`videoData` are preserved forcompat.
- `.canvaspkg/` (directory) is the editing/autosave format: atomic
  temp-write + rename, rotating recovery journal, never delete last-good
  before replacement validates. Single-file archive (`.canvasboard` zip) is
  deferred until the directory format is stable.
- Every persisted board has a schema version; migrations are deterministic
  with tests from every supported older version; unknown object types ride
  along as opaque foreign records with a recovery warning — never silent drop.
- Import validates extension *and* sniffs magic bytes, enforces size/duration
  limits, streams copy+hash off the UI thread with progress/cancel, inserts
  the object only on stable ref. Linked URLs are explicit opt-in
  (Copy-into-board vs. Keep-linked); no silent downloads, no tokens in files,
  path traversal rejected, numbers checked finite/bounded, no unwrap on user
  data.

### 7. Performance budgets (release, reference: Apple Silicon Mac)

- Pointer-down → visible selection: p95 < 16 ms (no main-thread I/O/decode).
- Pan/zoom: 60 fps target, 120 fps where display allows; coalesced moves,
  redraw at display cadence; cheap bbox before expensive hit tests.
- 10k lightweight objects navigable with grid-index culling; 1k mixed + media
  cards open without one-time UI freeze (async thumbnails/waveforms/posters).
- Autosave off UI thread, debounced + on milestones; no visible stall.
- Bounded caches (thumbs/layout/geometry/posters) with explicit invalidation;
  no unbounded decoded-media caches. Fixtures at 100/1k/10k/50k in
  `canvas` benches/tests; p50/p95/p99 + save duration tracked.

## Consequences

- Small reviewable commits; no large rewrite; upstream `openmind-vector`
  untouched.
- Behavioral parity with GazBoard (pan/zoom, pen/highlighter, stickies,
  shapes, tables, marquee, transforms, autosave, recovery, templates,
  import/export, shortcuts) without adopting its stack.
- Product identity: bundle `site.verysoft.openmind`, `OpenMind.app`,
  `.vsom` + `.canvaspkg`; upstream brand assets removed from renamed product
  per upstream brand license; MIT/Apache-2.0 notices preserved.
