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
    board/              whiteboard document model + `.vsom` board files
                        (byte-compatible with the Swift app's JSON format)
    ink/                pressure-aware inking core on the vector stack:
                        resample + smooth + variable-width outline paths,
                        eraser hit-testing, Swift StrokeCodec `[[x,y]]` compat
    canvas/             scene model: items, selection/groups/arrange, undo,
                        `.vsom` mapping (unknown kinds ride along untouched)
    app/                `openmind` desktop app (eframe canvas: select, shapes,
                        sticky/text, ink, images, `.vsom` save/open)
```

Later milestones add: `canvas` (viewport/selection engine), `render` (board →
scene via `vectorcraft-render`), `app` (eframe desktop), `web` (wasm),
`media` (audio/video/YouTube), packaging.

## Sibling checkout requirement

`ink` (and later crates) depend on `openmind-vector`'s crates **by path**
(`vectorcraft-geom`, `vectorcraft-brush`, …), reusing its battle-tested
Bézier geometry, brush tracks, text, and renderer instead of copying them.
Both repos must sit side by side:

```text
<parent>/openmind            this repo (branch openmind-rust)
<parent>/openmind-vector     itisverysoft/openmind-vector
```

## Milestones

- **M1 (this scaffold):** workspace, `board` model + `.vsom` round trip,
  `ink` stroke pipeline, headless render smoke test (ink → vector document
  → PNG via `vectorcraft-render`).
- **M2:** canvas engine (viewport, selection/marquee/groups/arrange ported
  from `CanvasView` + `CanvasGrouping`), shape items as vector paths.
- **M3:** inking depth — tablet pressure/tilt, eraser splitting, highlighter
  blending, stroke simplification budgets.
- **M4:** rich content — images, PDF pages, tables, pin notes, rich text.
- **M5:** media + export parity (PNG/PDF/SVG/`.vsom`), desktop app, web build.
- **M6:** hardening + packaging.

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
