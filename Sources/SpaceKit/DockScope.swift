// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Which windows a dock "owns": one or more screen regions, each paired with the
/// desktop (Space) visible on it. A normal per-display dock covers just its own
/// screen; the primary screen's dock can cover every screen, so an app dragged to
/// another monitor stays in the main dock. The same scope decides both what a dock
/// lists and what a click on it treats as "here" (focus vs. open a new window).
public struct DockScope: Equatable, Sendable {
    public struct Region: Equatable, Sendable {
        public let bounds: CGRect
        /// The Space visible on this screen. `nil`/0 = unknown → the snapshot's
        /// active Space is used instead.
        public let visibleSpace: SpaceID?

        public init(bounds: CGRect, visibleSpace: SpaceID?) {
            self.bounds = bounds
            self.visibleSpace = visibleSpace
        }
    }

    public let regions: [Region]
    /// Every attached display's bounds. With it, a window whose center is on *no*
    /// display (mid desktop-switch slide) is kept rather than dropped. `nil` =
    /// strict geometry (unit tests).
    public let allDisplays: [CGRect]?

    public init(regions: [Region], allDisplays: [CGRect]?) {
        self.regions = regions
        self.allDisplays = allDisplays
    }

    /// Whether `window` belongs to this dock. `activeSpace` stands in for any
    /// region whose visible Space is unknown.
    public func contains(_ window: WindowInfo, activeSpace: SpaceID) -> Bool {
        let onDesktop = regions.filter {
            Self.isOnVisibleDesktop(window, visibleSpace: Self.resolve($0.visibleSpace, activeSpace))
        }
        if onDesktop.contains(where: { window.isOnDisplay($0.bounds) }) { return true }
        // Not on any covered screen. Keep it only when its center is on no display
        // at all (a native desktop slide moves windows off-screen for a beat); if it
        // sits on an *uncovered* display, it belongs to that display's dock.
        guard let allDisplays, !onDesktop.isEmpty else { return false }
        return !allDisplays.contains { $0.contains(window.center) }
    }

    /// Which displays' windows the dock on `dock` lists (its own first). Every
    /// dock lists its own screen. Screens with *no* dock of their own are folded
    /// into a single host dock — the main display's if it has one, else the first
    /// dock by UUID — so no app is ever left without an icon:
    /// - dock on every screen → each lists only its own screen;
    /// - dock on the main screen only → it lists every screen;
    /// - selected screens → the undocked screens' apps land in the host dock.
    public static func coveredDisplayUUIDs(forDockOn dock: String, allDisplays: [String],
                                           docked: Set<String>, mainDisplay: String?) -> [String] {
        let host = mainDisplay.flatMap { docked.contains($0) ? $0 : nil } ?? docked.sorted().first
        guard dock == host else { return [dock] }
        return [dock] + allDisplays.filter { $0 != dock && !docked.contains($0) }
    }

    private static func resolve(_ space: SpaceID?, _ active: SpaceID) -> SpaceID {
        space.flatMap { $0 != 0 ? $0 : nil } ?? active
    }

    /// Whether `window` is on the desktop currently visible on its display (the one
    /// whose Space id is `visibleSpace`).
    ///
    /// - A window positively on `visibleSpace` is here, regardless of `onscreen`
    ///   (which goes false for a beat during a desktop slide).
    /// - A window on a *different* Space is not — so a window minimized on another
    ///   desktop of the same display doesn't leak into this one's dock.
    /// - When the window server reports **no Space** (membership is only reliable
    ///   for the active display), fall back to onscreen/minimized/hidden; the
    ///   geometric display test the caller pairs this with scopes it to a screen.
    static func isOnVisibleDesktop(_ window: WindowInfo, visibleSpace: SpaceID) -> Bool {
        if window.isOn(visibleSpace) { return true }
        if !window.spaceIDs.isEmpty { return false }
        return window.isOnVisibleSpace
    }
}
