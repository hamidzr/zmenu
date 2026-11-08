//! Colors. Anything the user configured stays a fixed sRGB color; everything
//! else is a dynamic system color, resolved by AppKit at draw time, so Light and
//! Dark mode (and the accent color) apply without any code running on a switch.

const objc = @import("objc");
const appconfig = @import("../config.zig");
const objc_helpers = @import("objc_helpers.zig");

const nsColor = objc_helpers.nsColor;
const nsString = objc_helpers.nsString;

pub const Palette = struct {
    text: objc.Object,
    secondary: objc.Object,
    /// text and secondary text on top of the selection fill
    selected_text: objc.Object,
    selected_secondary: objc.Object,
    selection_fill: objc.Object,
    hover_fill: objc.Object,
    field_fill: objc.Object,
    /// tint for matched characters
    accent: objc.Object,
};

fn systemColor(name: [:0]const u8) objc.Object {
    const NSColor = objc.getClass("NSColor").?;
    return NSColor.msgSend(objc.Object, name, .{});
}

fn withAlpha(color: objc.Object, alpha: f64) objc.Object {
    return color.msgSend(objc.Object, "colorWithAlphaComponent:", .{alpha});
}

fn configured(color: ?appconfig.Color) ?objc.Object {
    return if (color) |value| nsColor(value) else null;
}

pub fn palette(config: appconfig.Config) Palette {
    const white = systemColor("alternateSelectedControlTextColor");
    const text = configured(config.text_color) orelse systemColor("labelColor");
    const secondary = configured(config.secondary_text_color) orelse systemColor("secondaryLabelColor");

    var hover_fill = withAlpha(systemColor("labelColor"), 0.07);
    if (config.selection_color) |color| {
        var muted = color;
        muted.a *= 0.22;
        hover_fill = nsColor(muted);
    }

    return .{
        .text = text,
        .secondary = secondary,
        // an explicit text color is kept on the selection, as before
        .selected_text = configured(config.text_color) orelse white,
        .selected_secondary = configured(config.secondary_text_color) orelse withAlpha(white, 0.7),
        .selection_fill = configured(config.selection_color) orelse systemColor("selectedContentBackgroundColor"),
        .hover_fill = hover_fill,
        .field_fill = configured(config.field_background_color) orelse withAlpha(systemColor("labelColor"), 0.06),
        .accent = systemColor("controlAccentColor"),
    };
}
