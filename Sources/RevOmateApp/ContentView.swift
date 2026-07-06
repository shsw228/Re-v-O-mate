import SwiftUI
import RevOmateKit

// MARK: - Sidebar (hosted in the AppKit split view's sidebar pane)

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.section) {
            Label("Config", systemImage: "dial.medium.fill").tag(AppModel.Section.config)
            Label("Macros", systemImage: "wand.and.stars").tag(AppModel.Section.macros)
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Detail (hosted in the AppKit split view's content pane)

/// Root SwiftUI content shown to the right of the AppKit sidebar. Switches on
/// `model.section` and keeps a shared log strip at the bottom.
struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !model.isConnected {
                    ContentUnavailableView(
                        model.status == .connecting ? "Connecting…" : "Not connected",
                        systemImage: "cable.connector",
                        description: Text("Use Connect in the toolbar.")
                    )
                } else if model.config != nil {
                    switch model.section {
                    case .config: ConfigView(model: model)
                    case .macros: MacrosView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            LogView(model: model).frame(height: 96)
        }
    }
}

// MARK: - Toolbar status (hosted in an NSToolbarItem)

struct StatusView: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            Text(model.statusText).font(.callout).lineLimit(1)
            if let p = model.progress {
                ProgressView(value: p).frame(width: 80)
            } else if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .secondary
        case .connecting: .orange
        case .connected: .green
        case .error: .red
        }
    }
}

// MARK: - Log

struct LogView: View {
    var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.log.count) { _, n in
                withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .background(.background.secondary)
    }
}

// MARK: - Config section

struct ConfigView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let cfg = model.config {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Mode", selection: $model.selectedMode) {
                        ForEach(0..<FlashMap.modeCount, id: \.self) { Text("Mode \($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    ledEditor
                    dialFunctions(cfg)
                    dialActionEditor(cfg)
                    buttonEditor(cfg)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var ledEditor: some View {
        GroupBox("LED") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(model.ledSwatch)
                        .frame(width: 44, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Picker("", selection: $model.ledUseCustom) {
                        Text("Custom RGB").tag(true); Text("Preset").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .onChange(of: model.ledUseCustom) { model.previewLED() }
                    Spacer()
                    Button("Save LED") { model.saveLED() }.disabled(model.isBusy)
                }
                if model.ledUseCustom {
                    ledSlider("R", value: $model.ledR)
                    ledSlider("G", value: $model.ledG)
                    ledSlider("B", value: $model.ledB)
                } else {
                    HStack {
                        Text("Color").frame(width: 84, alignment: .leading)
                        Picker("", selection: $model.ledPreset) {
                            ForEach(0..<AppModel.presetNames.count, id: \.self) { Text(AppModel.presetNames[$0]).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                        .onChange(of: model.ledPreset) { model.previewLED() }
                        Spacer()
                    }
                }
                HStack {
                    Text("Brightness").frame(width: 84, alignment: .leading)
                    Picker("", selection: $model.ledBrightness) {
                        Text("Normal").tag(0); Text("Dark").tag(1); Text("Light").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .onChange(of: model.ledBrightness) { model.previewLED() }
                    Spacer()
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ledSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: 0...100) { editing in if !editing { model.previewLED() } }
                .onChange(of: value.wrappedValue) { model.previewLED() }
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }

    private func dialFunctions(_ cfg: ConfigImage) -> some View {
        GroupBox("Dial functions (current mode)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<FlashMap.functionsPerMode, id: \.self) { f in
                    let idx = model.selectedMode * FlashMap.functionsPerMode + f
                    let fn = cfg.functions[idx]
                    let isDefault = f == Int(cfg.modes[model.selectedMode].encoderFuncNo)
                    HStack(spacing: 8) {
                        Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isDefault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(cfg.functionNames[idx].isEmpty ? "—" : cfg.functionNames[idx])
                            .frame(width: 120, alignment: .leading)
                        Text("CW \(fn.cw.describe())   CCW \(fn.ccw.describe())")
                            .foregroundStyle(.secondary).font(.callout)
                        Spacer()
                    }
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dialActionEditor(_ cfg: ConfigImage) -> some View {
        GroupBox("Edit dial action") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $model.selectedFunc) {
                    ForEach(0..<FlashMap.functionsPerMode, id: \.self) { f in
                        let idx = model.selectedMode * FlashMap.functionsPerMode + f
                        let nm = cfg.functionNames[idx]
                        Text(nm.isEmpty ? "Function \(f)" : nm).tag(f)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                actionRow("CW ↻", draft: $model.cwDraft)
                actionRow("CCW ↺", draft: $model.ccwDraft)
                HStack {
                    Text("Applies after a mode switch / reconnect.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save dial function") { model.saveDialFunction() }.disabled(model.isBusy)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func buttonEditor(_ cfg: ConfigImage) -> some View {
        GroupBox("Edit button") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $model.selectedButton) {
                    ForEach(0..<FlashMap.swCount, id: \.self) { Text("SW\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack {
                    Text("Script").frame(width: 84, alignment: .leading)
                    Picker("", selection: $model.buttonScriptNo) {
                        Text("None").tag(0)
                        // Keep a tag for the currently-assigned script even before macros
                        // finish loading, so the selection isn't shown blank / reset on save.
                        if model.buttonScriptNo != 0,
                           !model.scripts.contains(where: { $0.number == model.buttonScriptNo }) {
                            Text("#\(model.buttonScriptNo) (loading…)").tag(model.buttonScriptNo)
                        }
                        ForEach(model.scripts) { e in
                            Text("#\(e.number) \(e.commands.first?.describe ?? "")").tag(e.number)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                    Text("Special func").frame(width: 96, alignment: .trailing)
                    Stepper("\(model.buttonSpFuncNo)", value: $model.buttonSpFuncNo, in: 0...255).frame(width: 110)
                    Spacer()
                }
                actionRow("Action", draft: $model.buttonDraft)
                HStack {
                    Text("Runs its script if set, else special func, else the direct action.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save button") { model.saveButton() }.disabled(model.isBusy)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Generalized action editor row: type picker + (keyboard) modifiers & key, or mouse payload.
    private func actionRow(_ label: String, draft: Binding<AppModel.ActionDraft>) -> some View {
        let d = draft.wrappedValue
        return HStack(spacing: 6) {
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
                .labelsHidden().frame(width: 90)
            } else if d.isMouseMove {
                Stepper("X \(d.moveX)", value: draft.moveX, in: -127...127).fixedSize()
                Stepper("Y \(d.moveY)", value: draft.moveY, in: -127...127).fixedSize()
            } else if d.isMouseScroll {
                Stepper("wheel \(d.wheel)", value: draft.wheel, in: -127...127).fixedSize()
            }
            Spacer()
        }
    }
}

// MARK: - Macros section

struct MacrosView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.scripts.isEmpty {
            ContentUnavailableView("No scripts", systemImage: "wand.and.stars",
                                   description: Text("This device has no stored macros (still loading, or none)."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                scriptForm
                Divider()
                commandTable
                Divider()
                commandBar
            }
        }
    }

    private var scriptForm: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Script").frame(width: 60, alignment: .leading)
                    Picker("", selection: scriptSelection) {
                        ForEach(model.scripts) { e in scriptLabel(e).tag(e.number) }
                    }
                    .labelsHidden()
                    Spacer()
                    Text("\(model.scriptByteCount) B").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Text("Name").frame(width: 60, alignment: .leading)
                    TextField("", text: $model.scriptName).frame(width: 200)
                    Spacer()
                }
                HStack {
                    Text("Mode").frame(width: 60, alignment: .leading)
                    Picker("", selection: $model.scriptMode) {
                        Text("Once").tag(ScriptInfo.Mode.oneShot)
                        Text("Loop").tag(ScriptInfo.Mode.loop)
                        Text("Fire").tag(ScriptInfo.Mode.fire)
                        Text("Hold").tag(ScriptInfo.Mode.hold)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer()
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding([.horizontal, .top], 12)
    }

    private var commandTable: some View {
        Table(indexed) {
            TableColumn("#") { (row: IndexedCommand) in
                Text("\(row.index + 1)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(28)
            TableColumn("Command") { (row: IndexedCommand) in commandOpcodePicker(row.index, row.command) }
            TableColumn("Parameter") { (row: IndexedCommand) in commandParam(row.index, row.command) }
        }
        .frame(minHeight: 200)
    }

    private var commandBar: some View {
        HStack {
            Menu("Add") {
                Button("Key press") { model.addCommand(.keyPress) }
                Button("Key release") { model.addCommand(.keyRelease) }
                Button("Wait") { model.addCommand(.wait) }
                Button("Mouse L press") { model.addCommand(.mousePressL) }
                Button("Mouse L release") { model.addCommand(.mouseReleaseL) }
                Button("Scroll up") { model.addCommand(.mouseScrollUp) }
                Button("Scroll down") { model.addCommand(.mouseScrollDown) }
            }
            .fixedSize()
            Button("Delete last") {
                if !model.scriptDraft.isEmpty { model.deleteCommand(at: [model.scriptDraft.count - 1]) }
            }
            .disabled(model.scriptDraft.isEmpty)
            Spacer()
            Text("Reconnect the device to run edited macros.").font(.caption).foregroundStyle(.secondary)
            Button("Save script") { model.saveScript() }.disabled(model.isBusy)
        }
        .padding(12)
    }

    private var scriptSelection: Binding<Int> {
        Binding(get: { model.selectedScriptNumber ?? -1 },
                set: { model.selectScript($0 == -1 ? nil : $0) })
    }

    private func scriptLabel(_ e: ConfigImage.ScriptEntry) -> Text {
        let first = e.commands.first?.describe ?? "empty"
        return Text("#\(e.number)\(usedBy(e.number))  \(first)")
    }

    struct IndexedCommand: Identifiable {
        let index: Int
        let command: ScriptCommand
        var id: UUID { command.id }
    }
    private var indexed: [IndexedCommand] {
        model.scriptDraft.enumerated().map { IndexedCommand(index: $0.offset, command: $0.element) }
    }

    private func usedBy(_ number: Int) -> String {
        guard let cfg = model.config else { return "" }
        for m in 0..<FlashMap.modeCount {
            for s in 0..<FlashMap.swCount where Int(cfg.modes[m].swExeScriptNo[s]) == number {
                return " (M\(m) SW\(s + 1))"
            }
        }
        return ""
    }

    private func commandOpcodePicker(_ index: Int, _ cmd: ScriptCommand) -> some View {
        Picker("", selection: Binding(get: { cmd.opcode }, set: { model.setOpcode(index, $0) })) {
            ForEach(ScriptOpcode.allCases, id: \.self) { Text(String(describing: $0)).tag($0) }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private func commandParam(_ index: Int, _ cmd: ScriptCommand) -> some View {
        switch cmd.opcode {
        case .keyPress, .keyRelease, .multiPress, .multiRelease:
            Picker("", selection: Binding(get: { cmd.data.first ?? 0 }, set: { model.setCommandByte(index, 0, $0) })) {
                ForEach(HIDKey.common) { Text($0.name).tag($0.usage) }
            }
            .labelsHidden()
        case .wait:
            let ms = UInt16(cmd.data[0]) << 8 | UInt16(cmd.data[1])
            Stepper("\(ms) ms", value: Binding(
                get: { Int(ms) }, set: { model.setWaitMs(index, UInt16(max(0, min(65535, $0)))) }
            ), in: 0...65535, step: 10)
        default:
            Text(cmd.data.isEmpty ? "—" : cmd.data.hexString).foregroundStyle(.secondary)
        }
    }
}
