import Charts
import CulpritCore
import ServiceManagement
import SwiftUI

struct PanelView: View {
    let monitor: Monitor
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowSection
            chartSection
            spikeSection
            Divider()
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
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Right now").font(.headline)
                Spacer()
                if let latest = monitor.latest {
                    Text(verbatim: "\(percent(latest.totalCores)) of \(ProcessInfo.processInfo.activeProcessorCount * 100)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            let apps = Array((monitor.latest?.apps ?? []).prefix(5))
            let scale = max(apps.first?.cores ?? 0, 1)
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    Text(app.name).lineLimit(1).truncationMode(.middle).frame(width: 170, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.tint)
                            .frame(width: geo.size.width * app.cores / scale)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    Text(percent(app.cores)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            if apps.isEmpty {
                Text("Collecting the first sample").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Chart

    private var chartSection: some View {
        let data = chartPoints(history: monitor.history)
        let colors = Self.palette(count: data.apps.count)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last 10 minutes").font(.headline)
            Chart(data.points) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("CPU", point.cores * 100),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("App", point.app))
            }
            .chartForegroundStyleScale(domain: data.apps, range: colors)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(verbatim: "\(Int(v))%") } }
                }
            }
            .frame(height: 150)
            // The built in legend clips long names, so draw one that truncates instead.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 3) {
                ForEach(Array(zip(data.apps, colors)), id: \.0) { name, color in
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(name).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }

    /// One color per named app, with gray kept for the trailing "Other" series.
    private static func palette(count: Int) -> [Color] {
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink]
        return Array(colors.prefix(max(count - 1, 0))) + [.gray.opacity(0.5)]
    }

    // MARK: Spikes

    private var spikeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spikes").font(.headline)
            if let current = monitor.currentSpike {
                spikeRow(current, ongoing: true)
            }
            ForEach(monitor.spikes.prefix(6)) { spike in
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
