# Testing Plan

## Unit

- `board`: vsom round trips, stable ids, asset hash/sniff, manifest, package
  atomicity + traversal, migrations (unknown preserved), validation.
- `canvas`: selection/marquee/groups/arrange, undo/redo, spatial insert/update/
  delete/query, transforms (resize floor, rotation norm), templates build,
  vsom interop (text/stroke/image + foreign carry-along).
- `text`: plain round trip, lenient decode, HTML sanitize (no scripts/tags),
  toggle bounds, emoji/CJK/RTL survival.
- `media`: import validates + dedups, rejects empty/unknown/oversize; YouTube
  forms + rejections; links credential refusal; preview staleness.
- `media-audio`: WAV round trip, waveform peaks, mock capture/player lifecycle.
- `media-video`: matrix documents YouTube separation, mock probe/poster/playback.
- `engine`: command grouping (one undo per transaction), locked/error paths;
  autosave debounce + atomic write + journal rotate/replay.
- `export`: PNG valid + scoped, SVG escapes + media notes, PDF header, manifest.

## Integration (see `rust/crates/canvas/tests/` + `engine`/`export` tests)

- Create → mixed objects → save → close → reopen → content + media intact.
- Record (mock) → stop → play → move card → save/reopen.
- Import video bytes → poster → open/play/seek/close.
- YouTube variants, invalid URLs, blocked embeds, offline state.
- Rich text edit → undo/redo → copy/paste → reopen.
- Low disk (write failure keeps last-good), corrupt media (contextual error,
  board intact), permission denial (actionable message), interrupted save
  (journal replay).

## Performance (release, Apple Silicon + Intel where available)

- Fixtures: 100 / 1k / 10k / 50k vector objects (`canvas` benches), 100 images,
  50 large text cards, 20 audio/video cards (one playing).
- Metrics: pointer-down→selection p50/p95/p99, frame time, text-edit latency,
  save latency, startup, peak RSS. Targets: selection p95 <16 ms, 60 fps pan/
  zoom (120 where capable), no main-thread I/O/decode, 10k navigable with
  culling, autosave without stalls. Thresholds in CI where stable; logs +
  fixtures kept for repro.
