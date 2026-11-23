import AppKit
import SwiftUI

/// 설정 창의 화면 상태. (Command Line Tools에는 SwiftUI의 @State가 없어서 ObservableObject로 대신한다)
@MainActor
final class SettingsUI: ObservableObject {
    /// 단축키를 새로 정하는 중인 항목.
    @Published private(set) var recordingID: UUID?
    @Published private(set) var recordHint: String?
    /// 아이콘 고르는 창이 열린 항목.
    @Published var pickerID: UUID?
    @Published var category = "all"
    @Published var query = ""

    let store: ShortcutStore
    private var monitor: Any?

    init(store: ShortcutStore) {
        self.store = store
    }

    /// 다음에 누르는 키를 이 항목의 단축키로 정한다. 누른 키는 다른 데로 보내지 않는다.
    func startRecording(_ id: UUID) {
        stopRecording()
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingID = nil
        recordHint = nil
    }

    private func record(_ event: NSEvent) {
        guard let id = recordingID else { return }
        let flags = event.modifierFlags.intersection(ShortcutRule.modifierMask)
        if event.keyCode == 53, flags.isEmpty { // esc: 그만두기
            stopRecording()
            return
        }
        // 글자 키 하나만으로는 타자 칠 때마다 뜨므로, 보조 키를 같이 누르게 한다 (F키는 혼자도 된다).
        guard !flags.subtracting(.shift).isEmpty || KeyNames.isFunctionKey(event.keyCode) else {
            recordHint = L("⌘, ⌥, ⌃ 중 하나와 같이 눌러 주세요 (F키는 혼자도 돼요)",
                           "Hold ⌘, ⌥, or ⌃ too (F-keys work alone)")
            NSSound.beep()
            return
        }
        store.update(id) { rule in
            rule.keyCode = event.keyCode
            rule.modifiers = flags.rawValue
            rule.label = KeyNames.label(for: event)
        }
        stopRecording()
    }
}

/// 설정 창 하나를 만들어 두고 다시 쓴다.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(ui: SettingsUI, preview: @escaping (String) -> Void) {
        if window == nil {
            let view = SettingsView(store: ui.store, ui: ui, preview: preview)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L("Liquid Toast 단축키", "Liquid Toast Shortcuts")
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 420))
            window.center()
            // 창을 닫으면 단축키 정하기와 아이콘 고르기도 그만둔다.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    ui.stopRecording()
                    ui.pickerID = nil
                }
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var ui: SettingsUI
    let preview: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("단축키를 누르면 고른 아이콘이 토스트로 떠요.", "Press a shortcut to show its icon as a toast."))
                .font(.headline)
            Text(L("키는 가로채지 않아서 원래 하던 일도 그대로 해요. macOS가 먼저 가져가는 시스템 단축키(⌥⌘D, 미션 컨트롤 등)는 잡을 수 없어요.",
                   "Keys are not intercepted, so they still do what they normally do. System shortcuts that macOS takes first (⌥⌘D, Mission Control, and so on) can't be seen."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !AXIsProcessTrusted() {
                Text(L("⚠️ 손쉬운 사용 권한을 허용해야 단축키를 볼 수 있어요.", "⚠️ Allow Accessibility access to see shortcuts."))
                    .font(.caption).foregroundStyle(.orange)
            }

            ScrollView {
                VStack(spacing: 6) {
                    if store.rules.isEmpty {
                        Text(L("아직 없어요. 아래 버튼으로 추가해 보세요.", "Nothing yet. Add one with the button below."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(store.rules) { rule in
                        RuleRow(rule: rule, store: store, ui: ui, preview: preview)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button(L("＋ 단축키 추가", "＋ Add Shortcut")) { store.add() }
                Spacer()
                if let hint = ui.recordHint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
    }
}

struct RuleRow: View {
    let rule: ShortcutRule
    @ObservedObject var store: ShortcutStore
    @ObservedObject var ui: SettingsUI
    let preview: (String) -> Void

    private var recording: Bool { ui.recordingID == rule.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { rule.enabled },
                                         set: { on in store.update(rule.id) { $0.enabled = on } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Button {
                    recording ? ui.stopRecording() : ui.startRecording(rule.id)
                } label: {
                    Text(recording ? L("키를 누르세요… (esc 취소)", "Press keys… (esc to cancel)")
                         : rule.label.isEmpty ? L("단축키 정하기", "Set Shortcut") : rule.label)
                        .font(rule.label.isEmpty || recording ? .body : .body.monospaced())
                        .frame(width: 170)
                }

                Image(systemName: "arrow.right").foregroundStyle(.tertiary)

                Button {
                    ui.query = ""
                    ui.pickerID = rule.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: rule.symbol).frame(width: 22)
                        Text(rule.symbol).lineLimit(1).truncationMode(.middle).frame(maxWidth: 130, alignment: .leading)
                    }
                }
                .popover(isPresented: Binding(get: { ui.pickerID == rule.id },
                                              set: { if !$0 { ui.pickerID = nil } }),
                         arrowEdge: .bottom) {
                    SymbolPicker(ui: ui, selected: rule.symbol) { name in
                        store.update(rule.id) { $0.symbol = name }
                    }
                }

                Spacer(minLength: 0)

                Button { preview(rule.symbol) } label: { Image(systemName: "play.fill") }
                    .help(L("미리 보기", "Preview"))
                Button { store.remove(rule.id) } label: { Image(systemName: "trash") }
                    .help(L("지우기", "Delete"))
            }
            if store.isDuplicate(rule) {
                Text(L("다른 항목과 단축키가 겹쳐요 (둘 다 떠요)", "Same shortcut as another item (both will show)"))
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 50)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// SF Symbols에서 아이콘 하나 고르기: 분류, 검색, 격자.
struct SymbolPicker: View {
    @ObservedObject var ui: SettingsUI
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        let names = SymbolCatalog.shared.filtered(category: ui.category, query: ui.query)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(L("검색 (영어로, 예: heart, music, arrow)", "Search (e.g. heart, music, arrow)"), text: $ui.query)
                    .textFieldStyle(.roundedBorder)
                Text("\(names.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SymbolCatalog.categories, id: \.key) { item in
                        Button(item.label) { ui.category = item.key }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(ui.category == item.key ? .accentColor : nil)
                    }
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        Button { onPick(name) } label: {
                            Image(systemName: name)
                                .font(.system(size: 20))
                                .frame(width: 42, height: 42)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(name == selected ? Color.accentColor.opacity(0.25) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 460, height: 420)
    }
}
