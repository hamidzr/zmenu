//! Plain geometry types with the same layout as NSPoint/NSSize/NSRect, so the
//! AppKit layer can pass them straight to Objective-C and tests can use them.

pub const Point = extern struct {
    x: f64,
    y: f64,
};

pub const Size = extern struct {
    width: f64,
    height: f64,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn minX(self: Rect) f64 {
        return self.origin.x;
    }

    pub fn minY(self: Rect) f64 {
        return self.origin.y;
    }

    pub fn maxX(self: Rect) f64 {
        return self.origin.x + self.size.width;
    }

    pub fn maxY(self: Rect) f64 {
        return self.origin.y + self.size.height;
    }

    /// half-open: the min edges are inside, the max edges are not
    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.minX() and point.x < self.maxX() and
            point.y >= self.minY() and point.y < self.maxY();
    }
};
