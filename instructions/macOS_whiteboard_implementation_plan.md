# Open Canvas — Implementation Plan for a High-Performance macOS Whiteboard

> **Purpose:** Build a robust, smooth, offline-first macOS whiteboard / moodboard / note-taking app using the Rust-native technology stack of [VectorCraft](https://github.com/storytold/vectorcraft), with workflow inspiration from [GazBoard](https://github.com/fahim9778/GazBoard).
>
> **Important:** This is an implementation plan, not a claim that every feature already exists in either repository. Before changing code, inspect the current branch and APIs. Keep the fork/reuse boundary explicit and preserve upstream license notices.

## 1. Product goals and non-negotiable principles

Build a macOS-first app with:

- An infinite canvas with fast pan/zoom, selection, drag, resize, rotate, layers, groups, and keyboard shortcuts.
- Freehand pen/highlighter, sticky notes, shapes, connectors, tables, rich-text objects, images, PDFs, and links.
- Audio recording from the microphone, imported audio files, audio URLs, video files, video URLs, and YouTube embeds.
- Offline-first board storage, autosave, crash recovery, undo/redo, import/export, and reliable file migration.
- Smooth interaction on large boards; UI interaction must not wait for expensive media decoding, file I/O, layout, or full-board rendering.
- Native macOS behavior: file open/save dialogs, drag and drop, permissions, keyboard shortcuts, trackpad gestures, accessibility, and a signed/notarized distributable app.

**Core design rule:** Canvas objects store lightweight metadata and references to media assets. They must not store decoded video frames, full-resolution image bitmaps, or entire audio files inside frequently-mutated object state.

## 2. Recommended technology stack

Keep the upstream VectorCraft stack wherever practical:

- **Language:** Rust.
- **Desktop UI:** existing VectorCraft `egui` frontend and its existing window/event integration, unless a documented prototype proves a specific macOS feature cannot be implemented well there.
- **Graphics:** reuse VectorCraft's `wgpu`-based rendering pipeline, geometry, text, and render infrastructure rather than adding a second canvas renderer.
- **Workspace/build:** Cargo workspace, existing `xtask`, lint, test, and release conventions.
- **Persistence:** versioned native board format, with a manifest plus separately stored media assets.
- **Audio/video:** isolate playback and capture behind Rust traits. Evaluate `cpal` for microphone capture and `symphonia` for audio decoding; evaluate `ffmpeg`/`ffmpeg-next` or a macOS-native AVFoundation bridge for video playback. Choose after checking licensing, codec coverage, packaging size, and Apple Silicon/Intel support.
- **YouTube:** a dedicated WebKit-based view or an external browser fallback. Do not attempt to decode YouTube streams by scraping private endpoints.
- **Rich text:** start with the text/layout facilities already present in VectorCraft. Add a structured rich-text document model and editing overlay; do not assume vector artwork text automatically provides word-processor-grade editing.

The VectorCraft repository describes its workspace as separate geometry, document, text, render, tools, engine, `ui-egui`, desktop, CLI, and web crates. Use those existing boundaries as the integration map. Confirm actual current names and APIs before implementation.

## 3. Phase 0 — Audit the repositories and establish a safe baseline

Do not start by adding media dependencies. First create a reproducible baseline.

### Step 0.1: Clone and build upstream

```bash
git clone https://github.com/storytold/vectorcraft.git
cd vectorcraft
git status --short
cargo xtask ci
cargo run --release -p vectorcraft
```

If a command differs on the current branch, follow `README.md` and `docs/development.md`. Record the Rust toolchain, macOS version, GPU, architecture (Apple Silicon or Intel), test results, and baseline launch/build times.

### Step 0.2: Inspect the codebase

Read these first:

- `README.md`, `AGENTS.md`, `ASSETS.md`, `NOTICE`
- `docs/development.md`, `docs/releasing.md`, `ROADMAP.md`
- `crates/doc`, `crates/engine`, `crates/tools`, `crates/render`, `crates/text`, `crates/ui-egui`
- `apps/vectorcraft`
- Existing file format, command/control protocol, import/export, and testkit code

Search for: document/object enums, command dispatch, undo/redo, serialization, render invalidation, hit testing, selection, keyboard routing, image import, text editing, file dialogs, drag/drop, app-data paths, and existing performance benchmarks.

### Step 0.3: Use GazBoard as a behavior checklist, not as the runtime architecture

Inspect GazBoard's README and source for user-visible behavior worth adapting: infinite pan/zoom, pen/highlighter, sticky notes, shapes, tables, lasso/marquee, object transforms, autosave, crash recovery, templates, document import, export, and shortcuts. GazBoard uses an Electron/JavaScript architecture; do not introduce Electron solely to copy its feature set when the goal is a Rust-native app.

### Step 0.4: Write an architecture decision record

Create `docs/adr/0001-product-architecture.md` that records:

1. What is reused unchanged from VectorCraft.
2. What is extended in the document model and UI.
3. What is implemented as a new crate/module.
4. Audio/video engine decision and licensing rationale.
5. Whether YouTube uses embedded WebKit or an external browser.
6. The media storage and migration strategy.
7. Measurable performance budgets.

Keep upstream changes in small, reviewable commits. Avoid a large unreviewable rewrite.

## 4. Phase 1 — Define the board model before building UI

### Step 1.1: Define a versioned board document

Introduce a board-level model in the existing document crate (or a focused crate if that is the established convention). A board should contain:

- Stable board ID, title, schema version, creation/modification timestamps.
- Canvas background and grid style.
- Ordered objects with stable IDs.
- Object geometry in **board/world coordinates**, not screen coordinates.
- Layer/group relationships, z-order, lock/visibility flags.
- Asset manifest references.
- Optional viewport state (camera position and zoom).
- App-level metadata kept separate from user content where possible.

Every object should have a stable ID. Do not use array index as identity; sorting or deletion must not invalidate references.

### Step 1.2: Add object types incrementally

Start with existing VectorCraft object primitives. Extend only where needed:

```rust
enum BoardObjectKind {
    // Reuse/bridge existing vector object types where possible.
    StickyNote(StickyNoteData),
    RichText(RichTextData),
    Connector(ConnectorData),
    Table(TableData),
    Image(ImageData),
    Audio(AudioData),
    Video(VideoData),
    Youtube(YoutubeData),
    PdfPage(PdfPageData),
}
```

This is illustrative, not a drop-in type definition. Fit it to the repository's current serialization and object architecture.

Common object properties should include ID, transform/bounds, z-order, opacity, lock state, and optional parent/group. Keep content-specific fields in each type. For connectors, store endpoint object IDs plus attachment anchors where feasible so lines remain attached as objects move.

### Step 1.3: Make edits command-based

All mutations should flow through a command/operation layer, not ad hoc UI writes. Examples:

- `AddObject`, `DeleteObjects`, `UpdateProperties`, `TransformObjects`
- `ReplaceRichText`, `SetAssetReference`, `MoveLayer`
- `BeginRecording`, `FinishRecording` should be media-service actions; only the resulting asset attachment is a board command.

Each committed user action should support undo/redo. Group continuous drag, pen strokes, text typing bursts, and resize operations into sensible undo transactions. Do not add every mouse-move event as a separate undo item.

### Step 1.4: Separate board data from binary assets

Use a package format such as:

```text
MyBoard.canvaspkg/
  manifest.json
  document.json
  assets/
    <sha256>.png
    <sha256>.m4a
    <sha256>.mp4
    <sha256>.pdf
  thumbnails/
  previews/
```

A single-file archive can be added later. During editing, a package directory is easier to recover and update safely. If a single-file format is required, implement atomic archive writing after the directory format is stable.

Asset references should include relative path or content hash, MIME/type, byte size, original filename, duration/dimensions where known, and optional generated thumbnail/waveform. Never trust a path from a board file without validating it stays inside the package or an explicitly permitted external location.

## 5. Phase 2 — Canvas interaction and performance

### Step 2.1: Preserve the upstream rendering path

Do not create an independent HTML canvas or a second GPU renderer. Extend the existing render pipeline with board objects. Keep drawing and hit-testing in world coordinates and transform to screen coordinates only at the view boundary.

### Step 2.2: Use viewport culling and spatial indexing

- Query only objects intersecting the visible world-space viewport.
- Add or reuse an R-tree, quadtree, or grid-based spatial index for hit testing and visible-object queries.
- Update index entries incrementally after object transforms.
- Keep selected objects and active gestures available even when their bounds cross the viewport edge.
- Use cheap bounding-box tests before expensive path/text hit tests.
- Avoid rebuilding the full index on every pointer move.

### Step 2.3: Keep interaction off expensive work

Pointer down should immediately update selection state and show selection chrome. It must not wait for image decoding, document parsing, media metadata probing, thumbnail generation, or disk writes.

- Move blocking file I/O and decoding to worker tasks.
- Send small results back to the UI thread through channels.
- Use cancellation tokens or generation IDs so stale async results cannot update deleted/replaced objects.
- Coalesce pointer-move updates and redraw at the display cadence.
- Never block the UI thread with a synchronous media process call.
- Avoid holding document locks while rendering or performing disk I/O.

### Step 2.4: Cache deliberately

Cache thumbnails, text layout, expensive vector geometry, image decode results, and video poster frames. Use bounded caches with memory budgets and explicit invalidation when source content changes. Avoid unbounded decoded-media caches.

For video, render a poster frame on the canvas and show live playback in a dedicated viewport/overlay when selected or playing. Do not decode every frame for every video object on the board.

### Step 2.5: Establish performance budgets

Measure before optimizing. Suggested initial targets on a documented reference Mac:

- Pointer-down to visible selection response: p95 below 16 ms.
- Pan/zoom while idle board content is visible: target 60 fps, and 120 fps on capable displays where feasible.
- No main-thread disk I/O or full media decode.
- 10,000 lightweight objects remain navigable with viewport culling.
- 1,000 mixed objects plus several media cards open without a large one-time UI freeze.
- Autosave writes do not cause visible interaction stalls.

These are engineering goals to validate, not promises. Track p50/p95/p99 latency, frame time, memory, and save duration in release builds. Add benchmark fixtures at 100, 1k, 10k, and 50k objects.

## 6. Phase 3 — Media asset service

Create a focused media subsystem (for example `crates/media` if compatible with the workspace layout). It should expose stable interfaces and keep UI code independent of codec implementation.

Suggested conceptual interfaces:

```rust
trait AssetStore {
    fn import_file(&self, source: &std::path::Path) -> Result<AssetRef>;
    fn resolve(&self, asset: &AssetRef) -> Result<AssetLocation>;
}

trait AudioCapture {
    fn start(&mut self, options: RecordingOptions) -> Result<RecordingSession>;
    fn stop(&mut self, session: RecordingSession) -> Result<RecordedAsset>;
}

trait MediaPreview {
    fn request_thumbnail(&self, asset: AssetRef, size: PreviewSize);
}
```

Adapt these to the app's actual async/runtime conventions. Avoid holding a borrowed mutable service in UI state across frames.

### Step 3.1: Import pipeline

1. Open native file picker or accept drag/drop/paste.
2. Validate extension **and** sniff file content; extension alone is not trustworthy.
3. Enforce configurable file-size and duration limits.
4. Copy or deduplicate into the board's asset store.
5. Compute a content hash in a background task.
6. Extract metadata and generate a thumbnail/waveform asynchronously.
7. Insert a board object only when the asset has a stable reference.
8. Report import errors clearly; keep the existing board intact on failure.

For large files, show progress and allow cancellation. Avoid reading the entire file into RAM; stream copy and hash where possible.

### Step 3.2: External media links

Support external URLs as references only when the user chooses linked media. Explain that links may break or require network access. Offer **Copy into board** for offline portability and **Keep linked** for space savings. Never silently download a remote file or embed credentials in a URL.

## 7. Phase 4 — Voice recording

### Step 4.1: Design the recording UX

- Toolbar action: **Record voice**.
- Ask macOS for microphone permission only when the user initiates recording.
- Show a visible recording state, elapsed time, pause/resume if supported, and Stop/Cancel actions.
- Show an input device selector if the chosen capture backend supports it.
- On stop, finalize the file, validate it, generate a waveform, and create an Audio card at the current viewport center.
- If the user cancels, discard the temporary file after confirmation when appropriate.
- If the app closes unexpectedly, recover or clean up partial recordings on next launch.

### Step 4.2: Implement safely

1. Add `NSMicrophoneUsageDescription` to the macOS app's `Info.plist` and ensure permission errors are actionable.
2. Prototype `cpal` capture and supported sample formats on both Apple Silicon and Intel. If native macOS capture offers better device selection/behavior, use a small, isolated AVFoundation bridge instead.
3. Capture samples on the audio callback with minimal work: no disk writes, UI updates, allocation-heavy processing, or blocking locks in the callback.
4. Push samples into a bounded producer/consumer buffer and write encoded audio from a dedicated worker.
5. Select a reliable recording format (for example, WAV for a simple initial implementation or AAC/M4A for smaller files if the chosen encoder is verified).
6. Flush and close the file before attaching it to the board.
7. Persist duration, codec/container, sample rate, channels, byte size, asset hash, and waveform metadata.
8. Test device unplugging, permission denial, low disk space, app termination, long recordings, and repeated start/stop cycles.

Do not promise lossless recovery of a recording that was never finalized. Clearly distinguish recoverable temporary data from completed audio assets.

## 8. Phase 5 — Audio attachments and playback

### Step 5.1: Audio card design

An Audio object should show title/filename, play/pause, elapsed/total duration, a seek bar, waveform, and optional notes/transcript text. Support resize and a compact card mode.

### Step 5.2: Playback architecture

- Implement an `AudioPlayer` interface with load, play, pause, seek, stop, and playback-state events.
- Evaluate `symphonia` for decoding formats that it supports; evaluate AVFoundation for a more native macOS playback path. Confirm format support rather than advertising every extension.
- Keep audio playback timing and buffering outside the canvas render loop.
- Multiple audio cards should not unexpectedly play simultaneously. Define a policy (for example, one active audio player by default).
- Stop or pause playback when a board closes, according to user settings.
- Handle missing files, decoder errors, output-device changes, and seeking near the end of a file.

### Step 5.3: Waveform generation

Generate a downsampled peak envelope in a background task. Store a compact array of peaks, not the full decoded PCM. Render the waveform with the existing vector/GPU pipeline. Cache it by content hash and algorithm version.

## 9. Phase 6 — Video files and network video

### Step 6.1: Decide the supported formats deliberately

Build a format support matrix before implementation. Distinguish:

- Local files that the backend can decode.
- Direct network URLs to supported media files.
- HLS/DASH streaming URLs, if explicitly supported by the selected playback engine.
- Web pages that merely contain a video player.
- YouTube URLs, handled by the separate YouTube feature.

A URL ending in `.mp4` is not proof that it is a valid or accessible MP4. Authentication, CORS, redirects, codecs, DRM, and network failures can all affect playback.

### Step 6.2: Local video

1. Import or link a video using the asset service.
2. Extract duration, dimensions, orientation, and a poster frame off the UI thread.
3. Insert a Video card that displays the poster, duration, and playback controls.
4. When the user plays it, open a dedicated video surface/overlay or inspector, not a permanently running decoder for every canvas card.
5. Support play/pause, seek, mute/volume, and fit/fill as feasible.
6. Ensure moving, zooming, or selecting the card does not restart playback unnecessarily.
7. Test large 4K files, variable frame rate, rotated phone videos, missing codecs, and corrupt media.

### Step 6.3: Playback engine choice

Prototype these alternatives in a small isolated spike before choosing:

- **AVFoundation via a narrow native bridge:** best fit for macOS system playback and supported system codecs; requires careful Rust/macOS interop.
- **FFmpeg-based playback:** broad codec capability, but adds packaging, performance, security-update, and LGPL/GPL compliance considerations. Review exact build flags and distribution obligations before shipping.
- **GStreamer or another media framework:** evaluate only if it materially improves required formats and packaging.

Do not build a custom video decoder. Choose one engine and hide it behind a stable interface so the board model does not depend on it.

### Step 6.4: Network video

- Accept direct HTTPS media URLs through an explicit **Add video from URL** flow.
- Show the domain and let users choose linked playback versus downloading a local copy.
- Use timeouts, bounded buffers, cancellation, and clear offline/error states.
- Do not automatically follow arbitrary local-network URLs or expose local files to web content.
- Handle redirects and MIME types carefully; avoid putting access tokens in persisted board metadata.
- If authentication is needed, prefer a system-controlled session or external browser rather than storing passwords in the board.
- Never bypass DRM or access controls.

## 10. Phase 7 — YouTube embedder

### Step 7.1: URL recognition

Recognize common public forms:

- `https://www.youtube.com/watch?v=VIDEO_ID`
- `https://youtu.be/VIDEO_ID`
- `https://www.youtube.com/shorts/VIDEO_ID`
- `https://www.youtube.com/embed/VIDEO_ID`

Validate the host and parse the video ID. Do not accept a user-provided arbitrary HTML snippet as trusted content.

### Step 7.2: Playback view

Use a WebKit-based native web view if the current app architecture can host it safely, or open the video in the user's browser as a fallback. Use YouTube's documented embed/player mechanism and comply with its current terms and branding requirements.

- Provide a preview thumbnail and **Play** action.
- Prefer click-to-load rather than loading many web views at board-open time.
- Pause/unload the embedded player when the object is offscreen or the board is inactive, subject to user expectations.
- Keep the web view isolated from the rest of the app. Do not enable arbitrary file access or expose unrestricted native bindings to page JavaScript.
- Do not try to download YouTube video streams or bypass ads, DRM, age gates, or regional restrictions.
- Be prepared for videos whose owners disable embedding, require sign-in, or are unavailable in the user's region. Offer **Open in YouTube** as fallback.

### Step 7.3: Keep the canvas responsive

A YouTube object should be a lightweight canvas card with a thumbnail until activated. WebKit should not run as a live embedded view for every YouTube object on a large board. Limit active web views and test memory use after repeatedly opening/closing videos.

## 11. Phase 8 — Rich-text editor

### Step 8.1: Define the content model

Represent rich text as structured content, not a single HTML string. Start with paragraphs and text runs supporting:

- Bold, italic, underline, strikethrough.
- Font family/size, text and highlight color.
- Paragraph alignment, indentation, bullet and numbered lists.
- Links, inline code, headings, and basic block quotes.
- Copy/paste from common macOS apps.
- Undo/redo, selection, keyboard navigation, and accessibility.

Use a versioned JSON/Serde model or the repository's existing text representation. Sanitize imported HTML and never execute embedded scripts.

### Step 8.2: Separate editing from display

- Render non-editing text through VectorCraft's existing text/render infrastructure where possible.
- When editing, show a focused text-editing surface/overlay with proper IME, selection, clipboard, and keyboard behavior.
- Keep the text editor's document model synchronized with the board command system.
- Commit undo transactions at natural boundaries (typing bursts, formatting actions, paste) rather than on every keystroke.
- Preserve the user's chosen manual box size; optionally offer auto-fit.
- Avoid rebuilding the entire canvas after every character. Invalidate only the text object, its layout cache, and affected selection chrome.

### Step 8.3: Text layout and measurement

Use a single layout source of truth for measurement and rendering. Test wrapping, mixed font runs, emoji, right-to-left text, CJK, links, and very long content. If the current VectorCraft text system cannot support editing requirements, document the gap and evaluate a dedicated editor component; do not bolt on a second unrelated text renderer without measuring the integration cost.

## 12. Phase 9 — Whiteboard and moodboard features

Implement these in order, reusing upstream capabilities where possible:

1. Infinite pan/zoom and configurable plain, grid, dotted, lined, and graph backgrounds.
2. Selection, multi-select, marquee/lasso, move/resize/rotate, lock, group, duplicate, z-order.
3. Sticky notes with color presets, text, and sensible auto-fit.
4. Pen, highlighter, eraser, pressure-aware stylus input where supported.
5. Shapes, arrows, connectors, and text inside shapes.
6. Rich-text cards and tables.
7. Image paste/import, crop/fit, PDF pages, and external links.
8. Audio recording, audio cards, video cards, YouTube cards.
9. Templates: brainstorming, mind map, SWOT, Kanban, meeting notes, project plan, moodboard, weekly planner.
10. Board gallery, search, recent boards, duplicate board, and export.
11. Optional later features: OCR, transcription, collaboration, sync, and AI assistance. Keep these out of the initial critical path.

### Drag/drop and paste

Use macOS file URLs and clipboard types supported by the existing UI stack. Import work should run asynchronously. A failed drop must not leave a broken object or corrupt the document. Provide a progress indicator for large imports.

## 13. Phase 10 — Autosave, recovery, and file safety

### Step 10.1: Autosave strategy

- Mark the document dirty on committed operations.
- Debounce saves, but also save at safe milestones (app background/close, board switch, after large imports).
- Serialize a consistent snapshot off the UI thread.
- Write to a temporary path, flush/sync as appropriate, then atomically replace the previous file.
- Keep a small rotating recovery journal or previous valid snapshot.
- Never delete the previous good board before the replacement is fully written and validated.
- Show a clear unsaved/recovery state when a save fails.

### Step 10.2: Schema migrations

Every persisted board has a schema version. Add deterministic migrations with tests from every supported older version. Never silently discard unknown object types: preserve them as opaque data or present a recovery warning where feasible.

### Step 10.3: Data integrity

- Validate all numbers for finiteness and reasonable bounds.
- Enforce package-relative asset paths and prevent path traversal.
- Treat imported documents, image metadata, media containers, URLs, and HTML as untrusted input.
- Bound decompression, image dimensions, object count, and metadata sizes.
- Avoid panic/unwrap on user-controlled data; return contextual errors.
- Back up before destructive migrations.
- Do not auto-delete original source files after import.

## 14. Phase 11 — Import, export, and portability

### Import

Start with image, SVG, PDF, and supported audio/video files. Add document import formats only after deciding whether to use native parsers, an external conversion tool, or a bundled converter. Communicate fidelity limitations honestly.

### Export

- PNG: whole board, viewport, or selection.
- SVG: vector-compatible objects where practical; media cards may export as thumbnails with a clear note.
- PDF: fit-to-page and tiled output.
- Native board package: preserve editability and assets.
- Optional media manifest: export a list of linked files and missing external references.

For YouTube/network URLs, export a link and preview rather than claiming the stream itself is embedded in a portable file. Document whether linked media remains external or is copied into the package.

## 15. Phase 12 — macOS polish and distribution

- Use macOS Open/Save panels and support opening a board by double-clicking it in Finder.
- Implement file association and a documented native extension (for example `.canvaspkg` or a single-file `.canvasboard` once the format is finalized).
- Add proper microphone usage text and request permission at the moment of need.
- Ensure accessibility labels, keyboard focus, VoiceOver support where practical, and reduced-motion considerations.
- Test trackpad pan/pinch, mouse, stylus where available, multiple displays, Retina scaling, sleep/wake, and external display changes.
- Build universal Apple Silicon + Intel artifacts if the toolchain/dependencies permit.
- Sign and notarize the final app. Audit all bundled codecs, fonts, icons, and libraries for licenses.
- Keep update/telemetry behavior transparent; default to local-only storage unless the user explicitly enables network features.

## 16. Testing strategy

### Unit tests

- Board serialization round trips and schema migrations.
- Command/undo/redo correctness.
- Object transforms and hit testing.
- Spatial-index insert/update/delete.
- Rich-text formatting and layout invalidation.
- URL parsing and YouTube host validation.
- Asset hash/deduplication and path validation.
- Audio metadata/waveform generation.
- Autosave atomicity and recovery journal replay.

### Integration tests

- Create board → add mixed objects → save → close → reopen → verify content and media.
- Record audio → stop → play → move the audio card → save/reopen.
- Import large video → generate poster → play → seek → close playback.
- YouTube URL variants, invalid URLs, blocked embeds, offline state.
- Edit rich text → undo/redo → copy/paste → reopen.
- Simulate low disk space, corrupt media, permission denial, and interrupted saves.

### Performance tests

Use release builds on at least one Apple Silicon Mac and, if supported, one Intel Mac. Test:

- 100 / 1,000 / 10,000 / 50,000 vector objects.
- 100 images with varied dimensions.
- 50 text cards with large content.
- 20 audio/video cards where only one video is actively playing.
- Repeated zooming and panning while autosave runs.
- Open/close media repeatedly and inspect memory for leaks.
- Measure pointer-down-to-selection, frame time, text-edit latency, save latency, startup time, and peak resident memory.

Add regression thresholds to CI where measurements are stable. Keep performance logs and benchmark fixtures so regressions can be reproduced.

## 17. Suggested workspace layout

Follow the existing workspace's conventions instead of forcing these exact names:

```text
crates/
  doc/                 # Board/object model, schema and migrations
  engine/              # Commands, undo/redo, app-level coordination
  render/              # Existing vector rendering + board object rendering
  tools/               # Selection, transforms, drawing and canvas tools
  text/                # Existing text engine + rich-text bridge
  media/               # New: asset store, metadata, thumbnails, waveform
  media-audio/         # Optional: capture/playback backend adapters
  media-video/         # Optional: video backend adapter
  ui-egui/             # Existing UI extended with board panels/cards
apps/
  vectorcraft/         # Rename/rebrand only after functionality is stable
docs/
  adr/
  architecture/
  testing/
```

Avoid splitting crates too early. A single `media` crate with internal modules may be easier initially; split only when dependencies or ownership boundaries justify it.

## 18. Implementation order and acceptance criteria

### Milestone A — Baseline and product shell

- [ ] Upstream builds and tests pass.
- [ ] App identity, bundle ID, icon, and board file naming are defined.
- [ ] Architecture decision record and benchmark baseline committed.

**Done when:** a clean checkout builds reproducibly and upstream functionality remains intact.

### Milestone B — Board document and object framework

- [ ] Versioned board model and stable IDs.
- [ ] Command-based mutations and undo/redo.
- [ ] Native board save/load and autosave recovery.
- [ ] Spatial indexing and visible-object culling.

**Done when:** mixed objects survive save/reopen and interactions remain responsive on the benchmark fixture.

### Milestone C — Core whiteboard

- [ ] Sticky notes, shapes, connectors, tables, drawing, eraser.
- [ ] Selection, transforms, layers/groups, shortcuts.
- [ ] Backgrounds and initial templates.

**Done when:** core interactions work without full-board rebuilds on every pointer event.

### Milestone D — Rich text and images/PDF

- [ ] Rich-text editing and undo/redo.
- [ ] Image import/paste/drag-drop and thumbnails.
- [ ] PDF page import and export baseline.

**Done when:** long text and large images do not freeze pan/zoom or corrupt the board.

### Milestone E — Audio

- [ ] Microphone permissions and recording UX.
- [ ] Audio import and playback.
- [ ] Waveform and asset persistence.
- [ ] Recovery/error tests.

**Done when:** recording, attaching, saving, reopening, and playback work reliably on target Macs.

### Milestone F — Video and YouTube

- [ ] Local video metadata/poster/playback.
- [ ] Direct network URL behavior and errors.
- [ ] YouTube URL parser and click-to-load embed.
- [ ] Playback lifecycle and memory tests.

**Done when:** unopened media cards remain lightweight, active playback works, and unsupported/blocked sources fail gracefully.

### Milestone G — Reliability and release

- [ ] Import fuzz/safety tests and migration tests.
- [ ] Performance regression suite.
- [ ] Accessibility and keyboard pass.
- [ ] License audit, signing, notarization, clean install/uninstall test.

**Done when:** no known data-loss issue remains, core performance targets are measured, and the app can be installed on a clean supported Mac.

## 19. How to use coding agents safely

Give an agent one milestone or one feature at a time. Ask it to:

1. Read `AGENTS.md` and the relevant architecture docs first.
2. Identify exact existing APIs and files before proposing edits.
3. Write a short plan and tests before changing code.
4. Avoid unrelated refactors and avoid adding dependencies without justification.
5. Run focused tests, then the repository's required CI command.
6. Report changed files, commands run, results, and remaining risks.
7. Keep each feature behind a narrow interface so media backends can be replaced.

Recommended first task prompt:

> Audit the current VectorCraft repository for the smallest safe path to add a board document model with stable object IDs, commands/undo-redo, and an asset manifest. Do not implement audio/video yet. Cite exact source files and existing APIs, identify conflicts with the current document format, propose a migration plan, and add tests for serialization and undo/redo before modifying unrelated modules.

## 20. Licensing, dependencies, and product identity

VectorCraft states that its code is dual-licensed under MIT or Apache-2.0, while bundled assets have their own licenses and the VectorCraft brand assets are separately restricted. Verify the current `LICENSE`, `NOTICE`, `ASSETS.md`, and individual dependency licenses before distributing a fork. Preserve required notices and remove upstream branding assets from a renamed product as required by the upstream brand license. Review GazBoard's license independently before copying any of its source code; behavioral inspiration does not require copying its implementation.

## 21. Final engineering recommendation

The most important sequencing decision is:

**Build and benchmark the board/object architecture first; add audio and video as asynchronous asset services second; add YouTube as an isolated web surface third.**

Do not make media decoding part of the canvas render loop, do not keep large binary media in frequently-mutated document objects, and do not rewrite the Rust rendering engine just to introduce whiteboard features. Reuse VectorCraft's geometry, rendering, text, document, and tooling foundations where they fit; add the missing board and media layers around them. This gives the project the best chance of being smooth, maintainable, and recoverable as boards grow.
