# OpenMind

An infinite-canvas whiteboard for macOS and iOS, built with SwiftUI and SwiftData.
Drop stickies, text, shapes, drawings, tables, pin notes, images, PDFs, audio,
video, and YouTube embeds on a freeform canvas — then export to PNG, PDF, SVG,
or shareable `.vsom` board files.

## Features

- Infinite canvas with pan, zoom, and optional fixed-size sheets (with pages)
- Stickies, text boxes (rich text), shapes, connectors, freehand drawing, tables, pin notes
- Images (photo picker, files, drag & drop, paste, image URLs)
- Audio (microphone voice notes, audio files, audio URLs) and video (files, video URLs)
- YouTube embeds (watch / share / Shorts links)
- Multi-select, marquee selection, duplicate, arrange, lock, undo/redo
- Board export: PNG, PDF, SVG, and `.vsom` files (open/import across devices)

## Requirements

- Xcode 16+
- macOS 14+ / iOS 17+ SDKs
- No API keys, accounts, or backend services needed — everything is local.

## Build & run

Open `OpenMind.xcodeproj` in Xcode and run the `OpenMind` scheme,
or from the terminal:

```sh
# Debug build for macOS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project OpenMind.xcodeproj -scheme OpenMind \
  -destination 'platform=macOS' build

# Release app bundle (ad-hoc signed; optionally installs to /Applications)
./scripts/build-app.sh
./scripts/build-app.sh --install
```

To sign with your own identity:

```sh
CODESIGN_IDENTITY="Apple Development: you@example.com" ./scripts/build-app.sh
```

## Tests

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project OpenMind.xcodeproj -scheme OpenMind \
  -destination 'platform=macOS'
```

## Privacy

OpenMind collects nothing: no analytics, no telemetry, no accounts.
Network access happens only when you ask for it (attaching a media URL,
playing a YouTube embed). Board data stays on-device in SwiftData.

## Contributing

Issues and pull requests are welcome. Please keep changes covered by tests
where practical (`OpenMindTests/`) and match the existing code style.

## About VerySoft

OpenMind is built by [VerySoft](https://openmind.verysoft.site).

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
