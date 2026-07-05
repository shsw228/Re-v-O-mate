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
        TabView {
            configTab(cfg).tabItem { Label("Config", systemImage: "dial.medium.fill") }
            macroTab(cfg).tabItem { Label("Macros", systemImage: "wand.and.stars") }
        }
    }

    private func configTab(_ cfg: ConfigImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $model.selectedMode) {
                ForEach(0..<FlashMap.modeCount, id: \.self) { Text("Mode \($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ledEditor
                    dialFunctions(cfg)
                    dialActionEditor(cfg)
                    buttons(cfg)
                    buttonEditor(cfg)
                }
            }
        }
        .padding(.top, 6)
    }

    private var ledEditor: some View {
        GroupBox("LED (live preview + save)") {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.ledSwatch)
                    .frame(width: 56, height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                VStack(spacing: 6) {
                    Picker("", selection: $model.ledUseCustom) {
                        Text("Custom RGB").tag(true); Text("Preset").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: model.ledUseCustom) { model.previewLED() }

                    if model.ledUseCustom {
                        ledSlider("R", value: $model.ledR)
                        ledSlider("G", value: $model.ledG)
                        ledSlider("B", value: $model.ledB)
                    } else {
                        HStack {
                            Text("Color").frame(width: 78, alignment: .leading)
                            Picker("", selection: $model.ledPreset) {
                                ForEach(0..<AppModel.presetNames.count, id: \.self) {
                                    Text(AppModel.presetNames[$0]).tag($0)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: model.ledPreset) { model.previewLED() }
                            Spacer()
                        }
                    }
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

    @ViewBuilder
    private func dialActionEditor(_ cfg: ConfigImage) -> some View {
        GroupBox("Edit dial action") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Function", selection: $model.selectedFunc) {
                    ForEach(0..<FlashMap.functionsPerMode, id: \.self) { f in
                        let idx = model.selectedMode * FlashMap.functionsPerMode + f
                        let nm = cfg.functionNames[idx]
                        Text(nm.isEmpty ? "Function \(f)" : nm).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                actionRow("CW  ↻", draft: $model.cwDraft)
                actionRow("CCW ↺", draft: $model.ccwDraft)

                HStack {
                    Text("Dial actions apply after a mode switch / reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save dial function") { model.saveDialFunction() }
                        .disabled(model.isBusy)
                }
            }
            .padding(6)
        }
    }

    /// A generalized action editor row: type picker + (for keyboard) modifiers & key.
    private func actionRow(_ label: String, draft: Binding<AppModel.ActionDraft>) -> some View {
        let d = draft.wrappedValue
        return HStack(spacing: 8) {
            Text(label).monospaced().frame(width: 64, alignment: .leading)
            Picker("", selection: draft.typeRaw) {
                ForEach(AppModel.editableTypes, id: \.self) { t in Text(SetType(t).description).tag(t) }
            }
            .labelsHidden().frame(width: 150)
            if d.isKeyboard {
                Toggle("⌃", isOn: draft.ctrl).toggleStyle(.button)
                Toggle("⇧", isOn: draft.shift).toggleStyle(.button)
                Toggle("⌥", isOn: draft.alt).toggleStyle(.button)
                Toggle("⌘", isOn: draft.cmd).toggleStyle(.button)
                Picker("", selection: draft.key) {
                    ForEach(HIDKey.common) { k in Text(k.name).tag(k.usage) }
                }
                .labelsHidden().frame(width: 100)
            } else if d.isMouseMove {
                Stepper("X \(d.moveX)", value: draft.moveX, in: -127...127).frame(width: 100)
                Stepper("Y \(d.moveY)", value: draft.moveY, in: -127...127).frame(width: 100)
            } else if d.isMouseScroll {
                Stepper("wheel \(d.wheel)", value: draft.wheel, in: -127...127).frame(width: 120)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func buttonEditor(_ cfg: ConfigImage) -> some View {
        GroupBox("Edit button action") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Button", selection: $model.selectedButton) {
                    ForEach(0..<FlashMap.swCount, id: \.self) { Text("SW\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Script").frame(width: 64, alignment: .leading)
                    Picker("", selection: $model.buttonScriptNo) {
                        Text("None").tag(0)
                        ForEach(model.scripts) { e in
                            Text("#\(e.number) \(e.commands.first?.describe ?? "")").tag(e.number)
                        }
                    }
                    .labelsHidden().frame(width: 200)
                    Text("Special func").frame(width: 90, alignment: .trailing)
                    Stepper("\(model.buttonSpFuncNo)", value: $model.buttonSpFuncNo, in: 0...255).frame(width: 110)
                }
                actionRow("Action", draft: $model.buttonDraft)
                Text("A button runs its script (if set), else its special func, else this direct action.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Text("Takes effect after a mode switch / reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save button") { model.saveButton() }.disabled(model.isBusy)
                }
            }
            .padding(6)
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

    // MARK: Macros

    @ViewBuilder
    private func macroTab(_ cfg: ConfigImage) -> some View {
        if model.scripts.isEmpty {
            ContentUnavailableView("No scripts", systemImage: "wand.and.stars",
                                   description: Text("This device has no stored macros."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Script", selection: Binding(
                    get: { model.selectedScriptNumber ?? -1 },
                    set: { model.selectScript($0 == -1 ? nil : $0) }
                )) {
                    ForEach(model.scripts) { e in
                        Text("#\(e.number)\(buttonUsing(e.number, cfg))  \(e.commands.first?.describe ?? "empty")")
                            .tag(e.number)
                    }
                }

                HStack {
                    TextField("Name", text: $model.scriptName).frame(width: 180)
                    Picker("Mode", selection: $model.scriptMode) {
                        Text("Once").tag(ScriptInfo.Mode.oneShot)
                        Text("Loop").tag(ScriptInfo.Mode.loop)
                        Text("Fire").tag(ScriptInfo.Mode.fire)
                        Text("Hold").tag(ScriptInfo.Mode.hold)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    Text("\(model.scriptByteCount) B").monospacedDigit().foregroundStyle(.secondary)
                }

                List {
                    ForEach(Array(model.scriptDraft.enumerated()), id: \.element.id) { i, cmd in
                        commandRow(i, cmd)
                    }
                    .onDelete { model.deleteCommand(at: $0) }
                    .onMove { model.moveCommand(from: $0, to: $1) }
                }
                .frame(minHeight: 220)

                HStack {
                    Menu("Add command") {
                        Button("Key press") { model.addCommand(.keyPress) }
                        Button("Key release") { model.addCommand(.keyRelease) }
                        Button("Wait") { model.addCommand(.wait) }
                        Button("Mouse L press") { model.addCommand(.mousePressL) }
                        Button("Mouse L release") { model.addCommand(.mouseReleaseL) }
                        Button("Scroll up") { model.addCommand(.mouseScrollUp) }
                        Button("Scroll down") { model.addCommand(.mouseScrollDown) }
                    }
                    Spacer()
                    Text("Reconnect the device to run edited macros.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save script") { model.saveScript() }.disabled(model.isBusy)
                }
            }
            .padding(.top, 6)
        }
    }

    private func buttonUsing(_ number: Int, _ cfg: ConfigImage) -> String {
        for m in 0..<FlashMap.modeCount {
            for s in 0..<FlashMap.swCount where Int(cfg.modes[m].swExeScriptNo[s]) == number {
                return " (M\(m) SW\(s + 1))"
            }
        }
        return ""
    }

    @ViewBuilder
    private func commandRow(_ index: Int, _ cmd: ScriptCommand) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { cmd.opcode },
                set: { model.setOpcode(index, $0) }
            )) {
                ForEach(ScriptOpcode.allCases, id: \.self) { Text(String(describing: $0)).tag($0) }
            }
            .labelsHidden().frame(width: 180)

            switch cmd.opcode {
            case .keyPress, .keyRelease, .multiPress, .multiRelease:
                Picker("", selection: Binding(
                    get: { cmd.data.first ?? 0 },
                    set: { model.setCommandByte(index, 0, $0) }
                )) {
                    ForEach(HIDKey.common) { Text($0.name).tag($0.usage) }
                }
                .labelsHidden().frame(width: 110)
            case .wait:
                let ms = UInt16(cmd.data[0]) << 8 | UInt16(cmd.data[1])
                Stepper("\(ms) ms", value: Binding(
                    get: { Int(ms) },
                    set: { model.setWaitMs(index, UInt16(max(0, min(65535, $0)))) }
                ), in: 0...65535, step: 10)
                .frame(width: 160)
            default:
                Text(cmd.data.isEmpty ? "" : cmd.data.hexString).foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
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
