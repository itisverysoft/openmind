//! Media asset service: stable interfaces, UI independent of codecs.
//!
//! [`AssetStore`] dedups by content hash; [`import`] validates extension +
//! magic bytes, enforces limits, and only then yields a stable [`AssetRef`].
//! Previews (thumbnails/waveforms/posters) are requested async and cached by
//! content hash — never decoded on the UI thread.

#![forbid(unsafe_code)]

pub mod links;
pub mod preview;
pub mod store;
pub mod youtube;

pub use links::{ExternalMedia, MediaLinkDecision};
pub use preview::{PreviewKind, PreviewRequest, PreviewSize};
pub use store::{AssetStore, FileAssetStore, ImportError, ImportLimits, ImportedAsset};
pub use youtube::{parse_youtube_url, YoutubeError, YoutubeRef};
