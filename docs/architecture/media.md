# Architecture — Media

- `media::AssetStore` (`FileAssetStore` rooted at the package): extension +
  magic sniff, size/duration limits, streamed copy+hash (SHA-256 hex, dedup),
  metadata + thumbnail/waveform requests async. Objects hold `AssetRef`
  (hash/mime/size/name/path/dims/duration/preview), never decoded bytes.
- `media::youtube`: host-validated `parse_youtube_url` (watch/youtu.be/shorts/
  embed), rejects HTML snippets, lookalike hosts, missing ids. `YoutubeRef`
  yields embed/watch/thumbnail URLs. Playback is click-to-load + external
  browser; blocked/private/regional videos show Open-in-YouTube. No scraping,
  no ad/DRM bypass, no tokens in files.
- `media::links::ExternalMedia`: explicit KeepLinked vs CopyIntoBoard, rejects
  credentials, non-http(s), overlong URLs. Local-network auto-fetch is never
  silent.
- `media-audio`: `AudioCapture` (bounded queue in callback, WAV encode on
  worker; `MockCapture` in default build, `cpal`/AVFoundation behind the same
  trait), `AudioPlayer` (load/play/pause/seek/stop + state; `MockPlayer`),
  `waveform_peaks` (compact u8 envelope, algo v1, cached by hash). One active
  player; board close stops playback. Recording format v1 is WAV.
- `media-video`: `FORMAT_MATRIX` (mp4/mov/webm/YouTube separation),
  `VideoBackend::probe/poster` + `VideoPlayback::open/play/pause/seek/mute/
  close` lifecycle. `MockVideoBackend`/`MockPlayback` cover lifecycle without
  system decoders. Moving/zooming/selecting never restarts playback.
- `text::RichTextDoc`: versioned paragraphs + runs (bold/italic/underline/
  strike, family/size/colors, align/indent, headings/quotes/lists/code/links),
  `sanitize_html` (drops script/style, decodes entities, no execution),
  lenient `decode` (never fails a board load).
- `export`: headless PNG (whole/viewport/selection), SVG (vector + media-as-
  thumbnail note + YouTube links), minimal valid PDF, native `.vsom`, media
  manifest (linked vs embedded). YouTube/network export as links + preview.
