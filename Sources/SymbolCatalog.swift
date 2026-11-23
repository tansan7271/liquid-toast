import AppKit

/// 고를 수 있는 SF Symbols 목록.
///
/// 공개 API에는 기호 목록이 없어서, 시스템 기호 묶음(CoreGlyphs.bundle)에 들어 있는 이름·분류·검색어 파일을
/// 읽는다 (읽기만 한다). 파일을 못 읽으면 자주 쓰는 기호 몇십 개로 대신한다.
/// 언어별 변형(.ar, .ko 같은 끝말)은 같은 그림이 겹쳐 보이기만 해서 뺀다.
@MainActor
final class SymbolCatalog {
    static let shared = SymbolCatalog()

    private(set) var names: [String] = []
    private var categoriesByName: [String: [String]] = [:]
    /// 이름마다 검색할 글 (이름 + 시스템 검색어, 소문자). 검색할 때마다 만들지 않게 미리 만들어 둔다.
    private var searchText: [String: String] = [:]

    /// 고르는 창에 보여 줄 분류 (시스템 분류 이름, 화면에 보일 이름).
    static let categories: [(key: String, label: String)] = [
        ("all", L("전체", "All")), ("communication", L("소통", "Communication")),
        ("media", L("미디어", "Media")), ("devices", L("기기", "Devices")),
        ("keyboard", L("키보드", "Keyboard")), ("connectivity", L("연결", "Connectivity")),
        ("objectsandtools", L("물건·도구", "Objects & Tools")), ("weather", L("날씨", "Weather")),
        ("nature", L("자연", "Nature")), ("human", L("사람", "Human")), ("home", L("집", "Home")),
        ("time", L("시간", "Time")), ("transportation", L("탈것", "Transportation")),
        ("gaming", L("게임", "Gaming")), ("health", L("건강", "Health")),
        ("fitness", L("운동", "Fitness")), ("commerce", L("쇼핑", "Commerce")),
        ("cameraandphotos", L("카메라", "Camera & Photos")), ("editing", L("편집", "Editing")),
        ("textformatting", L("글자", "Text")), ("arrows", L("화살표", "Arrows")),
        ("shapes", L("도형", "Shapes")), ("indices", L("숫자·글자", "Indices")),
        ("math", L("수학", "Math")), ("privacyandsecurity", L("보안", "Privacy & Security")),
        ("accessibility", L("손쉬운 사용", "Accessibility")), ("maps", L("지도", "Maps")),
    ]

    private init() {
        let folder = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        var all = plist("symbol_order.plist") as? [String] ?? []
        if all.isEmpty, let available = (plist("name_availability.plist") as? [String: Any])?["symbols"] as? [String: Any] {
            all = available.keys.sorted()
        }
        let localized = try? NSRegularExpression(pattern: #"\.(ar|he|hi|ja|ko|th|zh|rtl|bn|gu|kn|ml|mr|or|pa|ta|te|km|my|el|ru|sat|mni)$"#)
        names = all.filter { name in
            localized?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
        }
        if names.isEmpty {
            names = Self.fallback
        }
        categoriesByName = plist("symbol_categories.plist") as? [String: [String]] ?? [:]
        let keywords = plist("symbol_search.plist") as? [String: [String]] ?? [:]
        for name in names {
            searchText[name] = ([name] + (keywords[name] ?? [])).joined(separator: " ").lowercased()
        }
    }

    /// 분류와 검색어로 거른 목록. 검색어는 기호 이름과 시스템 검색어(영어)에서 찾는다.
    func filtered(category: String, query: String) -> [String] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return names.filter { name in
            if category != "all", !(categoriesByName[name] ?? []).contains(category) {
                return false
            }
            guard !words.isEmpty else { return true }
            let haystack = searchText[name] ?? name
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static let fallback = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "drop.fill", "sparkles", "moon.fill", "sun.max.fill",
        "bell.fill", "bookmark.fill", "tag.fill", "flag.fill", "pin.fill", "paperplane.fill", "envelope.fill",
        "message.fill", "phone.fill", "video.fill", "mic.fill", "mic.slash.fill", "camera.fill", "photo.fill",
        "music.note", "play.fill", "pause.fill", "stop.fill", "record.circle", "speaker.wave.2.fill",
        "display", "laptopcomputer", "keyboard", "printer.fill", "wifi", "lock.fill", "lock.open.fill",
        "key.fill", "trash.fill", "folder.fill", "doc.fill", "clipboard.fill", "pencil", "scissors",
        "magnifyingglass", "gearshape.fill", "hammer.fill", "wrench.fill", "cup.and.saucer.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill",
        "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.clockwise", "arrow.uturn.backward",
        "plus", "minus", "eye.fill", "eye.slash.fill", "hand.thumbsup.fill", "face.smiling",
    ]
}
