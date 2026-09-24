// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics

/// Geometry for keeping maximised windows clear of the dock, like the macOS Dock
/// does when it isn't auto-hiding. Pure, so it's unit-testable.
///
/// All rects are in global **top-left-origin** coordinates (what Accessibility
/// and Core Graphics use), so the bottom of the screen is `maxY`.
public enum ReservedArea {
    public enum Edge: Sendable { case bottom, top, left, right }

    /// The frame `window` should have so it doesn't extend behind a dock that
    /// reserves `inset` points along `edge` of `visible` (the screen's usable area
    /// — menu bar and macOS Dock already excluded), or nil to leave it alone.
    ///
    /// Only windows *snapped* to that edge are adjusted: their dock-side edge lies
    /// within `tolerance` of the visible edge, which is what zoom (green button /
    /// title-bar double-click), macOS tiling ("Fill", halves, quarters) and
    /// window managers produce. A window the user merely dragged over the bar is
    /// left alone, as with the native Dock.
    ///
    /// `previousInset` is the reservation windows were last trimmed to, when it has
    /// just changed (the dock grew or shrank). A window whose edge sits on that old
    /// line counts as snapped too, so it follows the dock: pushed in when the dock
    /// grows, let back out when it shrinks.
    ///
    /// A snapped window is resized to end at the reserved line; if that would make
    /// it smaller than `minLength`, it's moved clear instead.
    public static func adjusted(window w: CGRect, visible v: CGRect, edge: Edge, inset: CGFloat,
                                previousInset: CGFloat? = nil,
                                tolerance: CGFloat = 6, minLength: CGFloat = 120) -> CGRect? {
        guard inset >= 0, w.width > 0, w.height > 0 else { return nil }
        // Work along one axis: `pos` is the window's dock-side edge, `outer` the
        // visible edge the dock hugs, `sign` which way is "into the screen".
        let pos: CGFloat, outer: CGFloat, sign: CGFloat
        switch edge {
        case .bottom: (pos, outer, sign) = (w.maxY, v.maxY, -1)
        case .top:    (pos, outer, sign) = (w.minY, v.minY, 1)
        case .left:   (pos, outer, sign) = (w.minX, v.minX, 1)
        case .right:  (pos, outer, sign) = (w.maxX, v.maxX, -1)
        }
        let line = outer + sign * inset
        let snapped = abs(pos - outer) <= tolerance
            || previousInset.map { abs(pos - (outer + sign * $0)) <= tolerance } == true
        guard snapped, abs(pos - line) > 0.5 else { return nil }

        var r = w
        switch edge {
        case .bottom:
            if line - w.minY >= minLength { r.size.height = line - w.minY }
            else { r.origin.y = max(v.minY, line - w.height); r.size.height = line - r.minY }
        case .top:
            if w.maxY - line >= minLength { r.origin.y = line; r.size.height = w.maxY - line }
            else { r.origin.y = line; r.size.height = min(w.height, v.maxY - line) }
        case .left:
            if w.maxX - line >= minLength { r.origin.x = line; r.size.width = w.maxX - line }
            else { r.origin.x = line; r.size.width = min(w.width, v.maxX - line) }
        case .right:
            if line - w.minX >= minLength { r.size.width = line - w.minX }
            else { r.origin.x = max(v.minX, line - w.width); r.size.width = line - r.minX }
        }
        return r.integral == w.integral ? nil : r
    }
}
