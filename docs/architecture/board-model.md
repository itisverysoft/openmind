# Architecture — Board Model

- `board::StableBoard`: board id, title, schema v2, timestamps, background,
  ordered `BoardObject`s with stable ids, world-space `Transform`s, z/lock/
  hidden/group/parent/page, typed `BoardObjectKind`, optional viewport.
- `.vsom` stays the Swift-compatible interchange (v1, id-less records,
  embedded bytes). `canvas::vsom` maps native items ↔ records; unknown kinds,
  other pages, and unparseable blobs ride along in `CanvasDoc::foreign`.
- `.canvaspkg/` is the editing/autosave store: `manifest.json`
  (`BoardManifest`: asset dedup table + app metadata separate from content),
  `document.json` (`StableBoard`), `assets/<sha256>.<ext>`,
  `thumbnails/`, `previews/`, `recovery.json` journal.
- `board::validate`: finiteness, dimension/object-count/text bounds, no
  `unwrap` on user data. `board::package::resolve_asset` rejects traversal.
- `board::migrate::vsom_to_stable`: v1→v2 with fresh ids; unknown preserved as
  opaque `Unknown` + `MigrationReport`.

Connectors store endpoint ids + anchors so lines stay attached on move.
