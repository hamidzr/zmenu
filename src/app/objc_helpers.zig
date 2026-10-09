const std = @import("std");
const objc = @import("objc");
const appconfig = @import("../config.zig");
const io_compat = @import("../io_compat.zig");

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}

pub fn nsColor(color: appconfig.Color) objc.Object {
    const NSColor = objc.getClass("NSColor").?;
    return NSColor.msgSend(objc.Object, "colorWithSRGBRed:green:blue:alpha:", .{
        color.r,
        color.g,
        color.b,
        color.a,
    });
}

pub fn nsFont(size: f64) objc.Object {
    const NSFont = objc.getClass("NSFont").?;
    return NSFont.msgSend(objc.Object, "systemFontOfSize:", .{size});
}

// NSFontWeight values from AppKit. Exposed as plain f64 so callers do not need
// to know the enum.
pub const font_weight_regular: f64 = 0.0;
pub const font_weight_medium: f64 = 0.23;
pub const font_weight_semibold: f64 = 0.30;

pub fn nsFontWeight(size: f64, weight: f64) objc.Object {
    const NSFont = objc.getClass("NSFont").?;
    return NSFont.msgSend(objc.Object, "systemFontOfSize:weight:", .{ size, weight });
}

/// System font with tabular digits, so a changing counter does not jitter.
pub fn nsFontMonospacedDigit(size: f64, weight: f64) objc.Object {
    const NSFont = objc.getClass("NSFont").?;
    return NSFont.msgSend(objc.Object, "monospacedDigitSystemFontOfSize:weight:", .{ size, weight });
}

/// Full line box height for a font, used to size and centre single-line labels.
pub fn lineHeight(font: objc.Object) f64 {
    const ascender = font.msgSend(f64, "ascender", .{});
    const descender = font.msgSend(f64, "descender", .{});
    const leading = font.msgSend(f64, "leading", .{});
    const height = ascender - descender + leading;
    return if (height > 1.0) height else 16.0;
}

/// NSTextFieldCell leaves a small top inset, so single-line labels land a touch
/// below their frame centre. Nudge frames up by this much to keep glyphs optically
/// centred on the row or header axis.
pub const label_optical_offset: f64 = 1.25;

pub fn applyPlaceholderColor(
    field: objc.Object,
    placeholder: [*:0]const u8,
    color: objc.Object,
    font: objc.Object,
) void {
    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSAttributedString = objc.getClass("NSAttributedString").?;
    // include the font: a color-only attributed placeholder falls back to the
    // cell default (13pt) and renders smaller than the field text
    const attributes = NSMutableDictionary.msgSend(objc.Object, "dictionary", .{});
    attributes.msgSend(void, "setObject:forKey:", .{ color, nsString("NSColor") });
    attributes.msgSend(void, "setObject:forKey:", .{ font, nsString("NSFont") });
    const attributed = NSAttributedString.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:attributes:", .{ nsString(placeholder), attributes });
    field.msgSend(void, "setPlaceholderAttributedString:", .{attributed});
}

pub fn columnIsIndex(column: objc.Object) bool {
    const identifier = column.msgSend(objc.Object, "identifier", .{});
    const utf8_ptr = identifier.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return false;
    const name = std.mem.sliceTo(utf8_ptr.?, 0);
    return std.mem.eql(u8, name, "index");
}

pub fn columnIsIcon(column: objc.Object) bool {
    const identifier = column.msgSend(objc.Object, "identifier", .{});
    const utf8_ptr = identifier.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return false;
    const name = std.mem.sliceTo(utf8_ptr.?, 0);
    return std.mem.eql(u8, name, "icon");
}

var icon_cache: std.StringHashMapUnmanaged(?objc.Object) = .{};

/// Loads and retains the workspace icon for an absolute path, resized once
/// to the row size so per-draw scaling disappears. Missing and invalid paths
/// are cached as blank to avoid repeated filesystem checks.
pub fn iconImage(path: ?[:0]const u8, side: f64) ?objc.Object {
    const icon_path = path orelse return null;
    if (icon_path.len == 0 or !std.fs.path.isAbsolute(icon_path)) return null;
    if (icon_cache.get(icon_path)) |cached| return cached;

    const image = loadIconImage(icon_path, side);
    const key = std.heap.c_allocator.dupe(u8, icon_path) catch return image;
    icon_cache.put(std.heap.c_allocator, key, image) catch {
        std.heap.c_allocator.free(key);
        return image;
    };
    return image;
}

// image files draw their own pixels; iconForFile: would show the generic
// document icon for them
const image_extensions = [_][]const u8{ ".png", ".ico", ".svg", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".icns" };

fn isImageFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (image_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn loadIconImage(path: [:0]const u8, side: f64) ?objc.Object {
    io_compat.accessAbsolute(path, .{}) catch return null;

    // both branches yield a +1 retained image
    const image = if (isImageFile(path)) blk: {
        const NSImage = objc.getClass("NSImage").?;
        const loaded = NSImage.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithContentsOfFile:", .{nsString(path.ptr)});
        if (loaded.value == null) return null;
        break :blk loaded;
    } else blk: {
        const NSWorkspace = objc.getClass("NSWorkspace").?;
        const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
        const icon = workspace.msgSend(objc.Object, "iconForFile:", .{nsString(path.ptr)});
        if (icon.value == null) return null;
        break :blk icon.retain();
    };
    const side_len = @max(side, 1.0);
    image.msgSend(void, "setSize:", .{NSSize{ .width = side_len, .height = side_len }});
    return image;
}
