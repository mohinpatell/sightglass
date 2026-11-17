import SightglassCore
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
    @AppStorage("showAllMemory") private var showAllMemory = false
    @AppStorage("menuBarDividers") private var menuBarDividers = false
    /// True while the alert settings replace the panel's usual content.
    /// `-showAlertsPage YES` on the command line opens straight to them.
    @State private var showingAlerts = UserDefaults.standard.bool(forKey: "showAlertsPage")
    /// The row whose quit button was clicked, while the confirmation is up.
    @State private var quitTarget: AppUsage?
    @AppStorage("menuBarCPU") private var menuBarCPU = true
    @AppStorage("menuBarDraw") private var menuBarDraw = false
    @AppStorage("menuBarNet") private var menuBarNet = false

    private static let fullListHeight: CGFloat = 176
    private static let shortestListHeight: CGFloat = 88
    private var listIsExpanded: Bool {
        mode == "energy" ? showAllEnergy : mode == "memory" ? showAllMemory : showAllApps
    }
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
        .confirmationDialog(quitTarget.map { "Quit \($0.name)?" } ?? "", isPresented: Binding(
            get: { quitTarget != nil }, set: { if !$0 { quitTarget = nil } }
        ), presenting: quitTarget) { app in
            Button("Quit") { quit(app, force: false) }
            Button("Force Quit", role: .destructive) { quit(app, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Quit asks it to close, so it can save first. Force Quit stops it at once and unsaved work in it is lost.")
        }
        .onAppear {
            // `-testQuitDialog YES` on the command line opens the confirmation for the
            // busiest app, to check how it looks. Nothing is quit unless a button is clicked.
            guard UserDefaults.standard.bool(forKey: "testQuitDialog") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { quitTarget = monitor.latest?.apps.first(where: canQuit) }
        }
    }

    private var measuredContent: some View {
        content.background(GeometryReader { geo in
            Color.clear.preference(key: HeightKey.self, value: geo.size.height)
        })
    }

    private var content: some View {
        Group {
            if showingAlerts {
                AlertsPage(monitor: monitor) { showingAlerts = false }
            } else {
                mainContent
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("View", selection: $mode) {
                Text("CPU").tag("cpu")
                Text("Energy").tag("energy")
                Text("Memory").tag("memory")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == "energy" {
                EnergyPanel(monitor: monitor, listHeight: listHeight) { quitTarget = $0 }
            } else if mode == "memory" {
                MemoryPanel(monitor: monitor, listHeight: listHeight) { quitTarget = $0 }
            } else {
                nowSection
                chartSection
                spikeSection
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                intervalRow("Update on power", onBattery: false)
                intervalRow("Update on battery", onBattery: true)
                // The names are too long to share a line with the label, so it sits above,
                // with the choice of how readings are told apart beside it.
                HStack {
                    Text("Menu bar shows")
                    Spacer()
                    Picker("Separate readings with", selection: $menuBarDividers) {
                        Text("Icons").tag(false)
                        Text("Dividers").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("How readings are told apart when more than one is shown")
                }
                .padding(.top, 4)
                HStack(spacing: 6) {
                    menuBarToggle("CPU use", help: "How busy the processor is, out of 100", isOn: $menuBarCPU)
                    menuBarToggle("Power used", help: "Watts the whole Mac is drawing right now", isOn: $menuBarDraw)
                    menuBarToggle("Battery gain/loss", help: "Watts going into or out of the battery", isOn: $menuBarNet)
                }
                .onChange(of: [menuBarCPU, menuBarDraw, menuBarNet, menuBarDividers]) { monitor.refreshHeadline() }
                HStack {
                    Text("Alerts").frame(width: 122, alignment: .leading)
                    Button { showingAlerts = true } label: {
                        HStack {
                            let count = monitor.alertSettings.enabled.count
                            Text(count == 0 ? "Off" : "\(count) on")
                            Spacer()
                            Text("Choose").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            HStack {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        opensAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    /// A push button that stays down while on. Any combination can be on.
    private func menuBarToggle(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .help(help)
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
        UsageRow(name: app.name, fraction: app.cores / scale, value: percent(app.cores),
                 onQuit: canQuit(app) ? { quitTarget = app } : nil)
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
