import AppKit
import SwiftUI

/// The menu bar item is plain AppKit. SwiftUI's MenuBarExtra cost about 17 ms of main
/// thread time for every one second text change; setting a button title costs far less.
/// SwiftUI is only used for the panel, and only while the panel is open.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = Monitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var shownHeadline: String?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        draw(headline: nil)
        monitor.onHeadline = { [weak self] headline in
            guard let self, headline != self.shownHeadline else { return }
            self.shownHeadline = headline
            self.draw(headline: headline)
        }
        popover.behavior = .transient
        popover.delegate = self
        runDevFlags()
    }

    private func draw(headline: String?) {
        guard let button = statusItem.button else { return }
        if let headline {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.image = nil
            button.attributedTitle = NSAttributedString(string: headline, attributes: [.font: font])
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU Culprit")
        }
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // A transient popover only closes on an outside click while its app is active.
            NSApp.activate(ignoringOtherApps: true)
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        // Leave room for the menu bar and the popover's arrow.
        // `-panelMaxHeight 600` on the command line forces a short panel for testing.
        let forced = UserDefaults.standard.double(forKey: "panelMaxHeight")
        let limit = forced > 0 ? forced : (button.window?.screen?.visibleFrame.height ?? 800) - 30
        let controller = NSHostingController(rootView: PanelView(monitor: monitor, maxHeight: limit))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI view so nothing redraws while the panel is closed.
        popover.contentViewController = nil
    }

    /// Dev aids, since the panel cannot be clicked from a script:
    /// `--show-panel` opens the panel 3 seconds after launch.
    /// `--snapshot out.png` draws the panel to a file after 8 seconds and quits.
    private func runDevFlags() {
        let args = CommandLine.arguments
        if args.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.showPanel() }
        }
        guard let flag = args.firstIndex(of: "--snapshot"), args.count > flag + 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let renderer = ImageRenderer(content: PanelView(monitor: self.monitor).background(.background))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[flag + 1]))
            }
            exit(0)
        }
    }
}
