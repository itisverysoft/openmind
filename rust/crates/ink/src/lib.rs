//! Pressure-aware inking core for OpenMind, built on the vector stack.
//!
//! Raw pointer/tablet samples go in, filled variable-width outline paths
//! come out — the same nib-swept-stroke idea vector illustration apps use:
//!
//! 1. **Smooth**: one Chaikin pass keeps the hand's shape while removing
//!    sensor jitter (endpoints preserved).
//! 2. **Resample**: arc-length resampling at a width-derived spacing, so
//!    outline rails stay even at any drawing speed.
//! 3. **Frame**: tangents come from [`vectorcraft_brush::track`] frames
//!    (arc-length parameterised, corner-aware), widths from the pressure
//!    profile — pen tapers with pressure, highlighter holds full width.
//! 4. **Outline**: offset rails both sides with round caps, emitted as a
//!    single closed [`BezPath`] ready to fill.
//!
//! [`StrokeBuilder`] is the entry point; [`codec`] reads/writes the Swift
//! app's `StrokeCodec` `[[x,y]]` point blobs for board compatibility.

#![forbid(unsafe_code)]

pub mod codec;
pub mod stroke;

pub use stroke::{InkConfig, InkPoint, InkTool, SpinePoint, Stroke, StrokeBuilder};
pub use vectorcraft_geom::{BezPath, Point, Rect};
