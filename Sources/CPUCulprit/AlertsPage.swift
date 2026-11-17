import CulpritCore
import SwiftUI

/// The alert settings, shown in place of the panel's usual content.
struct AlertsPage: View {
    let monitor: Monitor
    let close: () -> Void

    private let durations: [(Double, String)] = [(1, "1 min"), (5, "5 min"), (15, "15 min")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Text("Alerts").font(.headline)
                HStack {
                    Button(action: close) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.link)
                    Spacer()
                }
            }
            Text("Each alert waits until the problem has lasted, so a brief blip never notifies you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            rule(.cpuHog) {
                Text("using more than")
                choice(\.hogCores, [(0.5, "half a core"), (1, "1 core"), (2, "2 cores"), (4, "4 cores")])
                Text("for")
                choice(\.hogMinutes, durations)
            }
            rule(.busyMac) {
                Text("CPU above")
                choice(\.busyShare, [(0.5, "50%"), (0.75, "75%"), (0.9, "90%")])
                Text("for")
                choice(\.busyMinutes, durations)
            }
            rule(.losingWhilePlugged) {
                Text("for at least")
                choice(\.losingMinutes, [(2, "2 min"), (5, "5 min"), (15, "15 min")])
            }
            rule(.batteryLow) {
                Text("less than")
                choice(\.lowBatteryMinutes, [(30, "30 min"), (60, "1 hour"), (120, "2 hours")])
                Text("left")
            }
            rule(.memoryPressure) {
                Text("when pressure is")
                choice(\.criticalPressureOnly, [(false, "high or critical"), (true, "critical")])
            }
            rule(.appMemory) {
                Text("more than")
                choice(\.appMemoryGigabytes, [(2, "2 GB"), (4, "4 GB"), (8, "8 GB"), (16, "16 GB")])
            }

            Divider()
            HStack(spacing: 4) {
                Text("Remind me again")
                choice(\.repeatMinutes, [(15, "every 15 min"), (60, "every hour"), (240, "every 4 hours"), (0, "only if it comes back")])
            }
            Toggle("Play a sound", isOn: binding(\.sound))

            VStack(alignment: .leading, spacing: 4) {
                Text("Muted apps").fontWeight(.semibold)
                let muted = monitor.alertSettings.mutedApps.sorted()
                if muted.isEmpty {
                    Text("None. An alert about an app comes with a button to stop alerts about that app, for jobs you started on purpose.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(muted, id: \.self) { name in
                    HStack {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Unmute") { monitor.updateAlerts { $0.mutedApps.remove(name) } }.buttonStyle(.link)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Send a test alert") { monitor.sendTestAlert() }
            }
        }
    }

    /// One alert: its switch, and under it the sentence that sets its limits.
    private func rule(_ kind: AlertKind, @ViewBuilder limits: () -> some View) -> some View {
        let isOn = monitor.alertSettings.enabled.contains(kind)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(kind.title, isOn: Binding(get: { isOn }, set: { monitor.setAlert(kind, on: $0) }))
            HStack(spacing: 4) { limits() }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.5)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AlertSettings, Value>) -> Binding<Value> {
        Binding(get: { monitor.alertSettings[keyPath: keyPath] },
                set: { value in monitor.updateAlerts { $0[keyPath: keyPath] = value } })
    }

    private func choice<Value: Hashable>(_ keyPath: WritableKeyPath<AlertSettings, Value>,
                                         _ options: [(Value, String)]) -> some View {
        Picker("", selection: binding(keyPath)) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}
