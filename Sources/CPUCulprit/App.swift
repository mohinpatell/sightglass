import AppKit
import CulpritCore
import SwiftUI

/// The menu bar item is plain AppKit. SwiftUI's MenuBarExtra cost about 17 ms of main
/// thread time for every one second text change; setting a button title costs far less.
/// SwiftUI is only used for the panel, and only while the panel is open.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = Monitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var shown: [MenuBarItem] = []

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
        draw([])
        monitor.onHeadline = { [weak self] items in
            guard let self, items != self.shown else { return }
            self.shown = items
            self.draw(items)
        }
        popover.behavior = .transient
        popover.delegate = self
        Notifier.shared.start()
        Notifier.shared.onMute = { [weak self] app in
            self?.monitor.updateAlerts { $0.mutedApps.insert(app) }
        }
        runDevFlags()
    }

    private let menuBarFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    /// Symbols are built once each. Rebuilding them every second cost more than drawing the text.
    private var symbols: [String: NSAttributedString] = [:]

    private func symbol(_ name: String) -> NSAttributedString? {
        if let cached = symbols[name] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: menuBarFont.pointSize - 2.5, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Sit the symbol on the text's optical center instead of its baseline.
        attachment.bounds = CGRect(x: 0, y: (menuBarFont.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        let text = NSAttributedString(attachment: attachment)
        symbols[name] = text
        return text
    }

    /// A thin, dimmed vertical line with a little air on each side.
    private lazy var divider: NSAttributedString = {
        let text = NSMutableAttributedString(string: "\u{2009}\u{2009}|\u{2009}\u{2009}")
        text.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor,
                            .font: NSFont.systemFont(ofSize: menuBarFont.pointSize - 1, weight: .light),
                            .baselineOffset: 1], range: NSRange(location: 2, length: 1))
        return text
    }()

    /// One reading is shown as a bare number. Two or more are told apart either by a
    /// small symbol in front of each, or by a divider between them, as the person chose.
    private func draw(_ items: [MenuBarItem]) {
        guard let button = statusItem.button else { return }
        guard !items.isEmpty else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU Culprit")
            return
        }
        let title = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { title.append(item.symbol == nil ? divider : NSAttributedString(string: "  ")) }
            if items.count > 1, let name = item.symbol, let symbol = symbol(name) {
                title.append(symbol)
                title.append(NSAttributedString(string: "\u{2009}"))
            }
            title.append(NSAttributedString(string: item.text, attributes: [.font: menuBarFont]))
        }
        button.image = nil
        button.attributedTitle = title
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
    /// `--test-alert` posts one notification 3 seconds after launch.
    /// `--snapshot out.png` draws the panel to a file after 8 seconds and quits.
    private func runDevFlags() {
        let args = CommandLine.arguments
        if args.contains("--test-alert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.monitor.sendTestAlert() }
        }
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
