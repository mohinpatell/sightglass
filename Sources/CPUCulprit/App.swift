import SwiftUI

@main
struct CPUCulpritApp: App {
    private let monitor = Monitor()

    init() {
        // Dev aid: `CPUCulprit --snapshot out.png` draws the panel to a file after
        // 8 seconds of sampling and quits, so the panel can be checked without clicking.
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), args.count > flag + 1 else { return }
        let monitor = monitor
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let renderer = ImageRenderer(content: PanelView(monitor: monitor).background(.background))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[flag + 1]))
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            if let headline = monitor.headline {
                Text(headline).monospacedDigit()
            } else {
                Image(systemName: "cpu")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
