import SwiftUI
import RevOmateKit

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deviceInfo
            logView
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 11, height: 11)
            Text(statusText)
                .font(.headline)
            Spacer()
            Button("Connect") { model.connect() }
                .disabled(model.status == .connecting)
            Button("Dump…") { model.dumpToFile() }
                .disabled(!model.isConnected)
        }
    }

    @ViewBuilder
    private var deviceInfo: some View {
        GroupBox("Device") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Firmware").foregroundStyle(.secondary)
                    Text(model.version ?? "—").monospaced()
                }
                GridRow {
                    Text("Scripts").foregroundStyle(.secondary)
                    Text(model.scriptCount.map(String.init) ?? "—").monospaced()
                }
                GridRow {
                    Text("Interface").foregroundStyle(.secondary)
                    Text("VID 0x22EA · PID 0x004B · UsagePage 0xFF00").monospaced().font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var logView: some View {
        GroupBox("Log") {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .secondary
        case .connecting: .orange
        case .connected: .green
        case .error: .red
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error(let m): "Error: \(m)"
        }
    }
}

#Preview {
    ContentView()
}
