// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

extension Notification.Name {
    /// Posted by Preferences' "Apply to Rectangle" button; the app delegate (which
    /// knows the live dock size) performs the sync.
    static let applyRectangleGaps = Notification.Name("powerspaces.applyRectangleGaps")
}

/// Writes Powerspaces' reserved strip into Rectangle's and Rectangle Pro's hidden
/// "screen edge gap" preferences, so their window actions stop at the dock in one
/// go instead of overlapping it until Powerspaces trims the window.
///
/// Rectangle only reads these at launch, so a running copy is quit, updated and
/// relaunched. Uses `CFPreferences`, the same store `defaults write` edits.
@MainActor
enum RectangleSync {
    struct Target {
        let bundleID: String
        let name: String
    }
    static let targets = [
        Target(bundleID: "com.knollsoft.Rectangle", name: "Rectangle"),
        Target(bundleID: "com.knollsoft.Hookshot", name: "Rectangle Pro"),
    ]

    /// Rectangle's key for the gap on each edge.
    private static func key(for edge: BarPosition) -> String {
        switch edge {
        case .bottom: return "screenEdgeGapBottom"
        case .top: return "screenEdgeGapTop"
        case .left: return "screenEdgeGapLeft"
        case .right: return "screenEdgeGapRight"
        }
    }

    /// Remembers what we last wrote per app, so moving the bar to another edge
    /// clears the old edge's gap — but only if it's still our value (a gap the
    /// user set themselves, e.g. for a menu-bar replacement, is left alone).
    private static func lastWrittenKey(_ bundleID: String) -> String { "rectangleSync." + bundleID }

    /// Apply `gap` points on `edge` (and main-screen-only when there's a single
    /// dock) to every installed Rectangle variant, restarting the running ones.
    /// Calls `completion` on the main thread with a summary for the HUD.
    static func apply(edge: BarPosition, gap: Int, mainScreenOnly: Bool,
                      completion: @escaping @MainActor (String) -> Void) {
        let installed = targets.compactMap { target -> (Target, URL)? in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID).map { (target, $0) }
        }
        guard !installed.isEmpty else {
            completion("Neither Rectangle nor Rectangle Pro is installed.")
            return
        }
        // Quit the running copies first: Rectangle reads these values at launch,
        // and a running copy could write its own preferences back over ours.
        let running = installed.flatMap { target, _ in
            NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID)
        }
        running.forEach { $0.terminate() }
        let wasRunning = Set(running.compactMap(\.bundleIdentifier))

        DispatchQueue.global(qos: .userInitiated).async {
            // Wait (briefly) for them to exit.
            let deadline = Date().addingTimeInterval(5)
            while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
                usleep(100_000)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (target, url) in installed {
                        write(target.bundleID, edge: edge, gap: gap, mainScreenOnly: mainScreenOnly)
                        if wasRunning.contains(target.bundleID) {
                            let config = NSWorkspace.OpenConfiguration()
                            config.activates = false
                            NSWorkspace.shared.openApplication(at: url, configuration: config)
                        }
                    }
                    let names = installed.map(\.0.name).joined(separator: " and ")
                    let restarted = wasRunning.isEmpty ? "" : " and restarted it"
                    completion("Set \(names)'s \(edge.label.lowercased()) screen gap to \(gap) pt\(restarted).")
                }
            }
        }
    }

    private static func write(_ bundleID: String, edge: BarPosition, gap: Int, mainScreenOnly: Bool) {
        let app = bundleID as CFString
        let store = UserDefaults.standard
        // Clear the gap we set on a previous edge, if the user hasn't changed it.
        if let last = store.dictionary(forKey: lastWrittenKey(bundleID)),
           let lastEdge = (last["edge"] as? String).flatMap(BarPosition.init(rawValue:)),
           let lastGap = last["gap"] as? Int, lastEdge != edge {
            let oldKey = key(for: lastEdge) as CFString
            let current = (CFPreferencesCopyAppValue(oldKey, app) as? NSNumber)?.intValue
            if current == lastGap { CFPreferencesSetAppValue(oldKey, nil, app) }
        }
        CFPreferencesSetAppValue(key(for: edge) as CFString, NSNumber(value: gap), app)
        CFPreferencesSetAppValue("screenEdgeGapsOnMainScreenOnly" as CFString,
                                 NSNumber(value: mainScreenOnly), app)
        CFPreferencesAppSynchronize(app)
        store.set(["edge": edge.rawValue, "gap": gap], forKey: lastWrittenKey(bundleID))
    }
}
