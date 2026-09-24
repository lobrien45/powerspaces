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

    private var observers: [pid_t: AXObserver] = [:]
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
    }

    /// Re-check every window now — after the dock appears, stops auto-hiding,
    /// changes size or position, or the screens change.
    func sweep() {
        guard isRunning else { return }
        for pid in observers.keys {
            let app = AXUIElementCreateApplication(pid)
            for window in Self.windows(of: app) { enforce(window) }
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

    private func enforce(_ window: AXUIElement) {
        // Don't fight a live drag/resize — check again once the button is up.
        if NSEvent.pressedMouseButtons & 1 != 0 { schedule(window); return }
        guard Self.isStandardWindow(window), !Self.isFullScreen(window),
              let frame = Self.frame(of: window),
              let screen = Self.screen(containing: frame),
              let reserved = reservation(screen),
              let target = ReservedArea.adjusted(window: frame,
                                                 visible: Self.topLeft(screen.visibleFrame),
                                                 edge: reserved.edge, inset: reserved.inset)
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
