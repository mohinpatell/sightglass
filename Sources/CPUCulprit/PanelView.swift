import CulpritCore
import ServiceManagement
import SwiftUI

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    let monitor: Monitor
    /// Tallest the panel may be, normally the height of the screen it opens on.
    var maxHeight: CGFloat = .infinity
    @State private var contentHeight: CGFloat = 0
    /// Height of an expanded "Show all" list: 8 rows, fewer if the screen is short.
    @State private var listHeight: CGFloat = PanelView.fullListHeight
    @AppStorage("showAllEnergy") private var showAllEnergy = false
    @AppStorage("menuBarCPU") private var menuBarCPU = true
    @AppStorage("menuBarDraw") private var menuBarDraw = false
    @AppStorage("menuBarNet") private var menuBarNet = false

    private static let fullListHeight: CGFloat = 176
    private static let shortestListHeight: CGFloat = 88
    private var listIsExpanded: Bool { mode == "energy" ? showAllEnergy : showAllApps }
    private var listCanShrink: Bool { listIsExpanded && listHeight > Self.shortestListHeight }
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// Remembered between opens, so the list stays the way it was left.
    @AppStorage("showAllApps") private var showAllApps = false
    @AppStorage("panelMode") private var mode = "cpu"

    /// A popover taller than the screen gets pushed sideways and bent out of shape by
    /// macOS. So when the content is too tall, the expanded list gives up rows first.
    /// Only if that is not enough does the whole panel scroll, at exactly `maxHeight`.
    var body: some View {
        Group {
            if contentHeight > maxHeight && !listCanShrink {
                ScrollView { measuredContent }.frame(width: 360, height: maxHeight)
            } else {
                measuredContent
            }
        }
        .onPreferenceChange(HeightKey.self) { height in
            contentHeight = height
            if height > maxHeight && listCanShrink {
                listHeight = max(Self.shortestListHeight, listHeight - (height - maxHeight))
            }
        }
    }

    private var measuredContent: some View {
        content.background(GeometryReader { geo in
            Color.clear.preference(key: HeightKey.self, value: geo.size.height)
        })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("View", selection: $mode) {
                Text("CPU").tag("cpu")
                Text("Energy").tag("energy")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == "energy" {
                EnergyPanel(monitor: monitor, listHeight: listHeight)
            } else {
                nowSection
                chartSection
                spikeSection
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                intervalRow("Update on power", onBattery: false)
                intervalRow("Update on battery", onBattery: true)
            }
            HStack {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        opensAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Menu("Menu bar") {
                    Toggle("CPU use", isOn: $menuBarCPU)
                    Toggle("Power the Mac is using", isOn: $menuBarDraw)
                    Toggle("Battery gain or loss", isOn: $menuBarNet)
                }
                .fixedSize()
                .onChange(of: [menuBarCPU, menuBarDraw, menuBarNet]) { monitor.refreshHeadline() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    /// The row for the power source in use right now is shown in bold.
    private func intervalRow(_ title: String, onBattery: Bool) -> some View {
        HStack {
            Text(title)
                .fontWeight(monitor.onBattery == onBattery ? .semibold : .regular)
                .frame(width: 122, alignment: .leading)
            Picker(title, selection: Binding(
                get: { onBattery ? monitor.intervalOnBattery : monitor.intervalOnPower },
                set: { monitor.setInterval($0, onBattery: onBattery) }
            )) {
                ForEach(Monitor.intervalChoices, id: \.self) { Text("\(Int($0))s").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Right now").font(.headline)
                Spacer()
                if let latest = monitor.latest {
                    // Whole machine out of 100, with the per core figures it comes from beside it.
                    Text(verbatim: "\(Int((latest.totalCores * 100).rounded()))% of \(Int(cpuCount) * 100)%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(totalPercent(latest.totalCores))
                        .font(.headline)
                        .monospacedDigit()
                }
            }
            // Everything that would show as more than 0.0%.
            let all = (monitor.latest?.apps ?? []).filter { $0.cores / cpuCount >= 0.0005 }
            let scale = max(all.first?.cores ?? 0, 1)
            if showAllApps {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(all) { appRow($0, scale: scale) }
                    }
                }
                .frame(height: listHeight)
            } else {
                ForEach(all.prefix(5)) { appRow($0, scale: scale) }
            }
            if all.isEmpty {
                Text("Collecting the first sample").foregroundStyle(.secondary)
            } else if all.count > 5 {
                Button(showAllApps ? "Show top 5" : "Show all \(all.count)") { showAllApps.toggle() }
                    .buttonStyle(.link)
            }
        }
    }

    private func appRow(_ app: AppUsage, scale: Double) -> some View {
        UsageRow(name: app.name, fraction: app.cores / scale, value: percent(app.cores))
    }

    // MARK: Chart

    private var chartSection: some View {
        let data = chartPoints(history: monitor.history, bucketSeconds: max(5, monitor.interval))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last 10 minutes").font(.headline)
            StackedChart(series: data.apps, points: data.points, scale: 100 / cpuCount, unit: "%")
        }
    }

    // MARK: Spikes

    private var spikeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spikes").font(.headline)
            if let current = monitor.currentSpike {
                spikeRow(current, ongoing: true)
            }
            ForEach(monitor.spikes.prefix(5)) { spike in
                spikeRow(spike, ongoing: false)
            }
            if monitor.currentSpike == nil && monitor.spikes.isEmpty {
                Text("None recorded yet").foregroundStyle(.secondary)
            }
        }
    }

    private func spikeRow(_ spike: Spike, ongoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if ongoing {
                    Text("Now").bold().foregroundStyle(.orange)
                } else {
                    Text(spike.start, format: Self.timeFormat(for: spike.start))
                }
                Text(ongoing ? "\(duration(spike.duration)) so far" : duration(spike.duration))
                Spacer()
                Text("peak \(percent(spike.peakCores))").foregroundStyle(.secondary)
            }
            .monospacedDigit()
            Text(spike.culprits.map { "\($0.name) \(percent($0.averageCores))" }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private static func timeFormat(for date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
    }
}

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
