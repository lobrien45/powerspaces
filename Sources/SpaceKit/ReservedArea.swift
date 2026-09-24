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
    /// left alone, as with the native Dock. A snapped window is shrunk to end at
    /// the reserved line; if that would make it smaller than `minLength`, it's
    /// moved clear instead.
    public static func adjusted(window w: CGRect, visible v: CGRect, edge: Edge, inset: CGFloat,
                                tolerance: CGFloat = 6, minLength: CGFloat = 120) -> CGRect? {
        guard inset > 0, w.width > 0, w.height > 0 else { return nil }
        var r = w
        switch edge {
        case .bottom:
            let line = v.maxY - inset
            guard abs(w.maxY - v.maxY) <= tolerance, w.maxY > line + 0.5 else { return nil }
            if line - w.minY >= minLength { r.size.height = line - w.minY }
            else { r.origin.y = max(v.minY, line - w.height); r.size.height = line - r.minY }
        case .top:
            let line = v.minY + inset
            guard abs(w.minY - v.minY) <= tolerance, w.minY < line - 0.5 else { return nil }
            if w.maxY - line >= minLength { r.origin.y = line; r.size.height = w.maxY - line }
            else { r.origin.y = line; r.size.height = min(w.height, v.maxY - line) }
        case .left:
            let line = v.minX + inset
            guard abs(w.minX - v.minX) <= tolerance, w.minX < line - 0.5 else { return nil }
            if w.maxX - line >= minLength { r.origin.x = line; r.size.width = w.maxX - line }
            else { r.origin.x = line; r.size.width = min(w.width, v.maxX - line) }
        case .right:
            let line = v.maxX - inset
            guard abs(w.maxX - v.maxX) <= tolerance, w.maxX > line + 0.5 else { return nil }
            if line - w.minX >= minLength { r.size.width = line - w.minX }
            else { r.origin.x = max(v.minX, line - w.width); r.size.width = line - r.minX }
        }
        return r.integral == w.integral ? nil : r
    }
}
