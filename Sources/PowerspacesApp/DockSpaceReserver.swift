// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import SpaceKit

/// Keeps maximised windows from extending behind a dock that isn't auto-hiding,
/// the way the macOS Dock reserves its strip of the screen.
///
/// macOS has no public API for a third-party app to shrink `NSScreen.visibleFrame`
/// (only the system Dock and menu bar can), so apps still zoom to the full area.
/// Instead this watches every app's windows through Accessibility and, a moment
/// after one is zoomed, tiled or created snapped to the dock's edge, trims it to
/// stop at the dock (see `ReservedArea`). Windows dragged over the bar by hand
/// are left alone, as with the native Dock.
@MainActor
final class DockSpaceReserver {
    /// For a screen: the edge and thickness (points, from the screen edge) its
    /// dock currently reserves, or nil when it reserves nothing (no dock, dock
    /// auto-hiding, full-screen app, feature off).
    var reservation: (NSScreen) -> (edge: ReservedArea.Edge, inset: CGFloat)? = { _ in nil }

    typealias Reservation = (edge: ReservedArea.Edge, inset: CGFloat)

    private var observers: [pid_t: AXObserver] = [:]
    /// What each display's windows were last trimmed against (display UUID →
    /// reservation). Compared on every `updateReservations()` so that when a dock
    /// grows, shrinks or moves edge, the windows trimmed to its old line follow it.
    private var applied: [String: Reservation] = [:]
    private var pending: [AXUIElement: DispatchWorkItem] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private(set) var isRunning = false

    /// Window events that can leave a window overlapping the dock.
    private static let notifications: [String] = [
        kAXWindowCreatedNotification, kAXWindowMovedNotification,
        kAXWindowResizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    // MARK: Lifecycle

    /// Start (or top up) observing. Idempotent: safe to call again, e.g. once
    /// Accessibility is granted, to attach to apps that failed before.
    func start() {
        guard AXIsProcessTrusted() else { return }
        if !isRunning {
            isRunning = true
            let ws = NSWorkspace.shared.notificationCenter
            workspaceTokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                  object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { app.map { self?.observeLaunched($0) } }
            })
            workspaceTokens.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                  object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { pid.map { self?.unobserve($0) } }
            })
        }
        NSWorkspace.shared.runningApplications.forEach(observe)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens.removeAll()
        Array(observers.keys).forEach(unobserve)
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        applied.removeAll()
    }

    /// Re-read every display's reservation (the dock's height, gap, edge or
    /// visibility may have changed) and, if any differ from what windows were last
    /// trimmed to, re-check every window: ones on the old line move to the new one.
    /// Cheap when nothing changed, so it's called on every dock refresh.
    func updateReservations() {
        guard isRunning else { return }
        var changes: [String: (old: Reservation, new: Reservation?)] = [:]
        var anyNew = false
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID else { continue }
            let now = reservation(screen)
            let old = applied[uuid]
            let same = now?.edge == old?.edge && abs((now?.inset ?? -1) - (old?.inset ?? -1)) < 0.5
            guard !same else { continue }
            if let old { changes[uuid] = (old, now) } else { anyNew = true }
            applied[uuid] = now
        }
        if anyNew || !changes.isEmpty { sweep(changes: changes) }
    }

    /// Re-check every window now (e.g. right after starting).
    func sweep() { sweep(changes: [:]) }

    private func sweep(changes: [String: (old: Reservation, new: Reservation?)]) {
        guard isRunning else { return }
        for pid in observers.keys {
            let app = AXUIElementCreateApplication(pid)
            for window in Self.windows(of: app) { enforce(window, changes: changes) }
        }
    }

    // MARK: Observation

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var added = false
        for name in Self.notifications {
            // Registered on the *application* element: its windows' notifications
            // bubble up to it, so new windows are covered without re-registering.
            if AXObserverAddNotification(observer, element, name as CFString, refcon) == .success { added = true }
        }
        guard added else { return } // app not AX-ready yet (or refuses); a later start() retries
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// A just-launched app often isn't answering Accessibility yet, so the first
    /// attach can fail; retry a couple of times while it finishes starting up.
    private func observeLaunched(_ app: NSRunningApplication, attempt: Int = 0) {
        observe(app)
        guard observers[app.processIdentifier] == nil, attempt < 3, !app.isTerminated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            MainActor.assumeIsolated { self?.observeLaunched(app, attempt: attempt + 1) }
        }
    }

    private func unobserve(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private static let callback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        let reserver = Unmanaged<DockSpaceReserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { reserver.schedule(element) }
    }

    /// Zoom and tiling animate through many resize/move events; wait for them to
    /// settle, then check once.
    private func schedule(_ window: AXUIElement) {
        pending[window]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending[window] = nil
                self?.enforce(window)
            }
        }
        pending[window] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Enforcement

    /// Trim `window` to its screen's reservation. `changes` carries, per display,
    /// the reservation windows were trimmed to before (so a window on that old
    /// line follows a dock that grew, shrank or moved to another edge).
    private func enforce(_ window: AXUIElement,
                         changes: [String: (old: Reservation, new: Reservation?)] = [:]) {
        // Don't fight a live drag/resize — check again once the button is up.
        if NSEvent.pressedMouseButtons & 1 != 0 { schedule(window); return }
        guard Self.isStandardWindow(window), !Self.isFullScreen(window),
              var frame = Self.frame(of: window),
              let screen = Self.screen(containing: frame) else { return }
        let visible = Self.topLeft(screen.visibleFrame)
        let change = screen.displayUUID.flatMap { changes[$0] }
        // The bar moved to another edge: release windows from the old edge's line
        // first. (When the reservation merely goes away — auto-hide, a full-screen
        // app — windows are left as they are, like the macOS Dock.)
        if let change, let new = change.new, new.edge != change.old.edge,
           let released = ReservedArea.adjusted(window: frame, visible: visible, edge: change.old.edge,
                                                inset: 0, previousInset: change.old.inset) {
            Self.setFrame(released, of: window)
            frame = released
        }
        guard let reserved = reservation(screen) else { return }
        let previous = change.flatMap { $0.old.edge == reserved.edge ? $0.old.inset : nil }
        guard let target = ReservedArea.adjusted(window: frame, visible: visible, edge: reserved.edge,
                                                 inset: reserved.inset, previousInset: previous)
        else { return }
        Self.setFrame(target, of: window)
    }

    // MARK: AX helpers

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success
        else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        string(window, kAXRoleAttribute) == kAXWindowRole
            && string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref) == .success
        else { return false }
        return (ref as? Bool) ?? false
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = frame.origin, size = frame.size
        // Position first so a shrink anchored at the far edge doesn't briefly
        // grow off-screen; size second.
        if let pos = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
        if let sz = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        }
    }

    /// AppKit's bottom-left global rect → the top-left global space AX uses
    /// (flipped about the primary screen's height).
    static func topLeft(_ rect: NSRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { topLeft($0.frame).contains(center) }
    }
}
