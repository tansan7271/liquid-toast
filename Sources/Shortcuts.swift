import AppKit

/// 사용자가 정한 "이 단축키를 누르면 이 아이콘을 띄운다" 하나.
struct ShortcutRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    /// 아직 단축키를 정하지 않았으면 nil.
    var keyCode: UInt16?
    /// ⌃⌥⇧⌘ 중 무엇을 같이 누르는지 (NSEvent.ModifierFlags의 rawValue).
    var modifiers: UInt = 0
    /// 화면에 보여 줄 이름 (예: "⌥⌘K"). 단축키를 정할 때 만들어 둔다.
    var label = ""
    /// 토스트에 띄울 SF Symbols 이름.
    var symbol = "star.fill"

    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        enabled && self.keyCode == keyCode && self.flags == flags.intersection(Self.modifierMask)
    }

    func sameShortcut(as other: ShortcutRule) -> Bool {
        keyCode != nil && keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// 단축키 목록 (UserDefaults에 저장, 다음 실행에도 유지).
@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var rules: [ShortcutRule] = []
    /// 목록이 바뀌면 불린다 (감시를 켜고 끄려고).
    var onChange: (() -> Void)?
    private let key = "shortcuts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ShortcutRule].self, from: data) {
            rules = saved
        }
    }

    /// 단축키가 정해져 있고 켜진 것이 하나라도 있나.
    var hasActiveRules: Bool { rules.contains { $0.enabled && $0.keyCode != nil } }

    func add() {
        rules.append(ShortcutRule())
        save()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func update(_ id: UUID, _ change: (inout ShortcutRule) -> Void) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        change(&rules[i])
        save()
    }

    /// 다른 항목과 같은 단축키인가 (겹치면 둘 다 뜬다).
    func isDuplicate(_ rule: ShortcutRule) -> Bool {
        rules.contains { $0.id != rule.id && $0.sameShortcut(as: rule) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
        onChange?()
    }
}

/// 정해 둔 단축키가 눌리는 걸 지켜본다. 보기만 하고 가로채지 않는다: 키는 평소대로 원래 앱에 간다.
///
/// 일반 키 입력을 받아야 해서, 정해 둔 단축키가 하나라도 있을 때만 켠다. 받은 키는 정해 둔 단축키와
/// 맞춰 보기만 하고 바로 버린다 (저장하거나 내보내지 않는다).
/// macOS가 먼저 가져가는 시스템 단축키(⌥⌘D, 미션 컨트롤 등)는 앱에 오지 않아서 잡을 수 없다.
@MainActor
final class ShortcutWatcher {
    var onMatch: ((ShortcutRule) -> Void)?
    /// 단축키를 새로 정하는 중이면 true를 돌려준다 (그동안은 맞춰 보지 않는다).
    var isPaused: () -> Bool = { false }
    private let store: ShortcutStore
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(store: ShortcutStore) {
        self.store = store
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        // 다른 앱이 앞에 있을 때 (손쉬운 사용 권한 필요)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // 이 앱의 설정 창이 앞에 있을 때
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        for monitor in [globalMonitor, localMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard !isPaused() else { return }
        for rule in store.rules where rule.matches(keyCode: event.keyCode, flags: event.modifierFlags) {
            onMatch?(rule)
        }
    }
}

/// 단축키 이름 만들기.
enum KeyNames {
    /// F1–F20. 이 키들은 보조 키 없이 혼자 눌러도 단축키로 쓸 수 있다.
    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let special: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: L("스페이스", "Space"), 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeys[keyCode] != nil }

    static func label(for event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(ShortcutRule.modifierMask)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        if let name = functionKeys[event.keyCode] ?? special[event.keyCode] {
            return text + name
        }
        // 보조 키를 빼고 눌렀을 때의 글자 (⌥나 ⇧ 때문에 바뀐 글자가 아니라 자판에 적힌 글자)
        let base = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        return text + (base.isEmpty ? "#\(event.keyCode)" : base)
    }
}
