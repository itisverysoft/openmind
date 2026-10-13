# Architecture — Rendering & Interaction

- Reuse `vectorcraft-geom`/`brush`/`color`/`doc`/`render` by path; no second
  GPU renderer, no HTML canvas. The eframe/egui canvas paints in world coords,
  converting to screen only at the view boundary (`Viewport`).
- `canvas::SpatialIndex`: uniform 512pt grid, incremental insert/update/remove,
  `query(viewport)` for culling, `rebuild` on load/undo/arrange. Selection +
  active gestures union with the visible set across edges. Cheap bbox before
  expensive path/text hits; no full-index rebuild on pointer move.
- Pointer-down updates selection + chrome immediately (<16 ms p95 goal); image
  decode, media probing, thumbnails, waveforms, posters, and disk writes run
  on workers with generation ids / cancellation. Moves coalesce at display
  cadence; document locks never held across render or I/O.
- Caches are bounded with explicit invalidation: egui textures (pruned to live
  visible images), text layout (per-object), waveform peaks (hash + algo v1),
  video posters (hash). No unbounded decoded-media caches. Video shows a
  poster; live decode runs only in a dedicated overlay for the one playing
  card. YouTube cards are thumbnail + click-to-load (external browser).
- `engine::BoardCommand` is the only mutation path; drags/strokes/typing burst
  into one undo item via `begin/end_transaction`. `AutosaveManager` debounces
  (2 s) + milestones, serializes off-thread, atomic temp + fsync + rename,
  rotating `RecoveryJournal` (depth 3). Last-good is never deleted before the
  replacement validates.
