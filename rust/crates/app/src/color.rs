/// Parse `RRGGBB` (with or without a leading `#`) into a color.
pub fn hex_color(hex: &str) -> egui::Color32 {
    let h = hex.strip_prefix('#').unwrap_or(hex);
    let v = u32::from_str_radix(h.get(0..6).unwrap_or(""), 16).unwrap_or(0x808080);
    egui::Color32::from_rgb(
        ((v >> 16) & 0xFF) as u8,
        ((v >> 8) & 0xFF) as u8,
        (v & 0xFF) as u8,
    )
}
