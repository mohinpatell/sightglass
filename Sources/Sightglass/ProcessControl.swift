import AppKit
import SightglassCore

/// Rows that are leftovers or system components, not something that can be quit.
func canQuit(_ app: AppUsage) -> Bool {
    !app.pids.isEmpty && ![shortLivedName, unidentifiedName, systemEnergyName].contains(app.name)
}

/// Quits what a row stands for.
///
/// A regular app with that name is asked the way the Dock asks, so it can prompt to
/// save. Anything else (a script, a command line tool, a background helper) gets
/// SIGTERM. With `force` everything is stopped at once and nothing is saved.
func quit(_ app: AppUsage, force: Bool) {
    let running = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.bundleURL?.deletingPathExtension().lastPathComponent == app.name
    }
    if running.isEmpty || force {
        signal(pids: app.pids, force: force)
    }
    for application in running {
        if force { application.forceTerminate() } else { application.terminate() }
    }
}
