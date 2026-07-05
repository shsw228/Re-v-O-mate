import SwiftUI
import RevOmateKit

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isConnected, let cfg = model.config {
                editor(cfg)
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "cable.connector",
                    description: Text("Connect a Rev-O-mate and press Connect.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            logView
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 560)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 11, height: 11)
            Text(statusText).font(.headline)
            if let v = model.version { Text("FW \(v)").foregroundStyle(.secondary).monospaced() }
            if model.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Connect") { model.connect() }.disabled(model.status == .connecting)
            Button("Backup…") { model.backup() }.disabled(!model.isConnected)
        }
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ cfg: ConfigImage) -> some View {
        Picker("Mode", selection: $model.selectedMode) {
            ForEach(0..<FlashMap.modeCount, id: \.self) { Text("Mode \($0)").tag($0) }
        }
        .pickerStyle(.segmented)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ledEditor
                dialFunctions(cfg)
                buttons(cfg)
            }
        }
    }

    private var ledEditor: some View {
        GroupBox("LED (live preview + save)") {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.ledSwatch)
                    .frame(width: 56, height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                VStack(spacing: 6) {
                    ledSlider("R", value: $model.ledR)
                    ledSlider("G", value: $model.ledG)
                    ledSlider("B", value: $model.ledB)
                    HStack {
                        Text("Brightness").frame(width: 78, alignment: .leading)
                        Picker("", selection: $model.ledBrightness) {
                            Text("Normal").tag(0); Text("Dark").tag(1); Text("Light").tag(2)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: model.ledBrightness) { model.previewLED() }
                    }
                }
                VStack {
                    Button("Save") { model.saveLED() }.disabled(model.isBusy).keyboardShortcut("s")
                }
            }
            .padding(6)
        }
    }

    private func ledSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 78, alignment: .leading)
            Slider(value: value, in: 0...100) { editing in
                if !editing { model.previewLED() }
            }
            .onChange(of: value.wrappedValue) { model.previewLED() }
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }

    private func dialFunctions(_ cfg: ConfigImage) -> some View {
        GroupBox("Dial functions") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<FlashMap.functionsPerMode, id: \.self) { f in
                    let idx = model.selectedMode * FlashMap.functionsPerMode + f
                    let fn = cfg.functions[idx]
                    let isDefault = f == Int(cfg.modes[model.selectedMode].encoderFuncNo)
                    HStack {
                        Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isDefault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text("\"\(cfg.functionNames[idx].isEmpty ? "—" : cfg.functionNames[idx])\"")
                            .frame(width: 130, alignment: .leading)
                        Text("CW \(fn.cw.describe())   CCW \(fn.ccw.describe())")
                            .foregroundStyle(.secondary).font(.callout)
                        Spacer()
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func buttons(_ cfg: ConfigImage) -> some View {
        let mode = cfg.modes[model.selectedMode]
        let rows = (0..<FlashMap.swCount).compactMap { s -> String? in
            var parts: [String] = []
            if mode.swExeScriptNo[s] != 0 { parts.append("script #\(mode.swExeScriptNo[s])") }
            if mode.swSpFuncNo[s] != 0 { parts.append("spFunc \(mode.swSpFuncNo[s])") }
            let direct = cfg.swFunctions[model.selectedMode * FlashMap.swCount + s]
            if !direct.isEmpty { parts.append(direct.action.describe()) }
            return parts.isEmpty ? nil : "SW\(s + 1): \(parts.joined(separator: ", "))"
        }
        return GroupBox("Buttons") {
            if rows.isEmpty {
                Text("(none assigned)").foregroundStyle(.secondary).padding(6)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.self) { Text($0).font(.callout) }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Log

    private var logView: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(4)
            }
            .frame(height: 90)
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
        case .connected: "Rev-O-mate"
        case .error(let m): "Error: \(m)"
        }
    }
}

#Preview {
    ContentView()
}
