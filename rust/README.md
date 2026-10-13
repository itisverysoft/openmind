# OpenMind Rust

A Rust rewrite of [OpenMind](../README.md) (SwiftUI + SwiftData whiteboard),
built **like `openmind-vector`**: a Cargo workspace of small crates, a robust
vector inking core, and — later — an `eframe`/`egui` desktop + web app.

The Swift app is untouched and stays the reference implementation until the
Rust app reaches parity.

## Layout

```text
rust/
  Cargo.toml            workspace (members: crates/*)
  crates/
    board/              whiteboard document model + `.vsom` (Swift-compatible)
                        + StableBoard v2, asset refs, manifest, `.canvaspkg/`,
                        validation, migrations, atomic package I/O
    ink/                pressure-aware inking core on the vector stack:
                        resample + smooth + variable-width outline paths,
                        eraser hit-testing, Swift StrokeCodec `[[x,y]]` compat
    canvas/             scene model: items, selection/groups/arrange, undo,
                        spatial grid index + culling, transforms, connectors,
                        tables, rich text, audio/video/YouTube/PDF cards,
                        templates, `.vsom` mapping (unknown kinds ride along)
    text/               structured rich-text docs + HTML sanitize
    media/              AssetStore, import pipeline, YouTube URLs, links, previews
    media-audio/        AudioCapture/AudioPlayer traits, WAV, waveform peaks
    media-video/        format matrix, probe/poster/playback lifecycle
    engine/             command layer + undo grouping + autosave/recovery
    export/             PNG/SVG/PDF/native/manifest exporters (headless)
    app/                `openmind` desktop (eframe canvas: tools, media cards,
                        templates, gallery flows, export, autosave, shortcuts)
```

See `../docs/adr/0001-product-architecture.md` for the reuse/extend/new
boundary, engine choices, YouTube policy, storage/migration, and budgets.

## Sibling checkout requirement

`ink` (and later crates) depend on `openmind-vector`'s crates **by path**
(`vectorcraft-geom`, `vectorcraft-brush`, …), reusing its battle-tested
Bézier geometry, brush tracks, text, and renderer instead of copying them.
Both repos must sit side by side:

```text
<parent>/openmind            this repo (branch openmind-rust)
<parent>/openmind-vector     itisverysoft/openmind-vector
```

## Milestones (plan §18; all landed in this branch)

- **A — Baseline & shell:** upstream builds, bundle `site.verysoft.openmind`,
  `.vsom`/`.canvaspkg` naming, ADR + benchmark baseline. Done when clean
  checkout builds reproducibly.
- **B — Board & objects:** versioned model + stable ids, commands/undo,
  native save/load + autosave recovery, spatial index + culling. Done when
  mixed objects survive reopen and stay responsive on fixtures.
- **C — Core whiteboard:** stickies/shapes/connectors/tables/ink/eraser,
  selection/transforms/layers/groups/shortcuts, backgrounds + templates. Done
  when interactions avoid full-board rebuilds.
- **D — Rich text & images/PDF:** structured rich text + undo, image
  import/paste/drag-drop + thumbnails, PDF baseline. Done when long text and
  large images don't freeze pan/zoom.
- **E — Audio:** mic permission + recording UX, import/playback, waveform +
  persistence, recovery/error tests. Done when record→attach→reopen→play works.
- **F — Video & YouTube:** metadata/poster/playback, direct-URL behavior,
  URL parser + click-to-load embed, lifecycle/memory tests. Done when unopened
  cards stay lightweight and blocked sources fail gracefully.
- **G — Reliability & release:** fuzz/safety + migration tests, perf suite,
  keyboard/accessibility pass, license audit, signing/notarization, clean
  install test. Done when no known data-loss remains and the app installs clean.

Legacy scaffold milestones M1–M6 are subsumed by A–G above.

## Commands

```sh
./scripts/install.sh              # release build + tests + install bins to ~/.local/bin
./scripts/install.sh --no-test    # skip tests
./scripts/install.sh --uninstall  # remove installed bins

cd rust
cargo build            # all crates
cargo test             # unit + integration tests
cargo test -p openmind-board
cargo test -p openmind-ink
```

## Conventions

- `#![forbid(unsafe_code)]` in every crate.
- Fallible work returns `Result`/`Option`; no panics on user data paths.
- Wire formats stay byte-compatible with the Swift app (`.vsom` JSON:
  base64 `Data`, `Date` as seconds since 2001-01-01). Round-trip tests pin it.
