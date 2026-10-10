# OpenMind (Rust rewrite)

An infinite-canvas whiteboard, rewritten in Rust — built like
[`openmind-vector`](https://github.com/itisverysoft/openmind-vector): a Cargo
workspace of small crates with a robust vector inking core, targeting desktop
(macOS/Windows/Linux) and web.

> **Branch note:** this branch (`openmind-rust`) holds the Rust rewrite. The
> original SwiftUI + SwiftData app lives on `main` and in this branch's
> history; `.vsom` board files stay compatible between the two.

## Features (target parity with the Swift app)

- Infinite canvas with pan, zoom, and optional fixed-size sheets (with pages)
- Stickies, text boxes, shapes, connectors, freehand drawing, tables, pin notes
- Images, PDFs, audio, video, and YouTube embeds
- Multi-select, marquee selection, duplicate, arrange, lock, undo/redo
- Board export: PNG, PDF, SVG, and `.vsom` files (open/import across devices)

## Layout

```text
rust/
  crates/
    board/   whiteboard document model + `.vsom` files (Swift-compatible)
    ink/     pressure-aware inking on the vector stack (geom + brush tracks)
```

See [`rust/README.md`](rust/README.md) for milestones and conventions.

## Requirements

- Rust 1.85+ (`rustup show` to verify)
- A sibling checkout of `openmind-vector` (path dependencies — see below)
- No API keys, accounts, or backend services — everything is local.

## Build & test

Both repos must sit side by side (`openmind-vector` provides the `geom`,
`brush`, `color`, `doc`, and `render` crates by path):

```text
<parent>/openmind            this repo (branch openmind-rust)
<parent>/openmind-vector     itisverysoft/openmind-vector
```

```sh
cd rust
cargo build
cargo test
```

## Privacy

OpenMind collects nothing: no analytics, no telemetry, no accounts.
Network access happens only when you ask for it (attaching a media URL).
Board data stays on-device.

## About VerySoft

OpenMind is built by [VerySoft](https://verysoft.site).

- 🌐 Project site: [openmind.verysoft.site](https://openmind.verysoft.site)
- ✉️ Email: [itisverysoft@gmail.com](mailto:itisverysoft@gmail.com)
- 𝕏 X: [x.com/itisverysoft](https://x.com/itisverysoft)
- ▶️ YouTube: [youtube.com/@itisverysoft](https://youtube.com/@itisverysoft)
- 📸 Instagram: [instagram.com/itisverysoft](https://instagram.com/itisverysoft)
- 📘 Facebook: [facebook.com/itisverysoft](https://facebook.com/itisverysoft)

Maintainer's personal website: [shoibur.pro.bd](https://shoibur.pro.bd)

## Support OpenMind

If OpenMind is useful to you, you can support its development:

- 💚 [Supportkori](https://www.supportkori.com/srksifat)
- ☕ [Buy me a coffee](https://buymeacoffee.com/shoibur)

## License

MIT — see [LICENSE](LICENSE).
