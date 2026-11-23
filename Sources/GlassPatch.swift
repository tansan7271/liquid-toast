import QuartzCore
import Foundation

/// 토스트 유리의 생김새. 맑고 굴절이 강한 유리가 되도록 눈으로 보며 맞춘 값.
enum GlassTuning {
    static let refraction: Double = 150      // 곡면에서 뒤 화면이 휘는 정도
    static let bevel: Double = 30            // 가장자리에서 안쪽으로 곡면이 이어지는 폭 (pt)
    static let outerRefraction: Double = 0   // 모양 바깥쪽 굴절
    static let outerBevel: Double = 150
    static let profile0: Double = -0.007     // 곡면 단면 (뜻이 확인되지 않은 시스템 값)
    static let profile1: Double = 0
    static let highlight: Double = 0.7       // 가장자리 반사광
    static let highlightAngle: Double = 90   // 도
    static let aberration: Double = 30       // 색수차
    static let blur: Double = 0              // 0이면 흐림 단계를 아예 건너뛰어 그리는 부담이 준다
    static let lightBG: Double = 0.25        // 밝은 배경을 조금 어둡게
    static let darkBG: Double = 1            // 어두운 배경을 조금 밝게
}

/// 시스템 유리 필터 값을 직접 바꾼다 (Rainpane에서 쓰던 방식).
/// 공개 API에는 굴절·흐림 조절이 없어서 유리 레이어의 `glassBackground` 필터 값을 덮어쓴다.
/// 비공개 구현이라 macOS가 바뀌면 효과가 없어질 수 있다 (그래도 기본 유리로 보일 뿐 깨지지는 않는다).
/// 유리 모양이 바뀔 때마다 시스템이 값을 다시 계산해 넣으므로(확인함), 모양을 놓은 직후마다 다시 불러야 한다.
enum GlassPatch {
    private static let clearFill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)

    /// `root` 아래의 유리 필터를 전부 찾아 값을 넣는다. 찾은 개수를 돌려준다.
    /// strength(0…1)는 렌즈 세기 배율: 모양이 작을수록 낮춰야 굴절이 모양 밖 엉뚱한 곳을 읽지 않는다.
    @discardableResult
    static func apply(_ root: CALayer, strength: Double = 1) -> Int {
        var top = root
        while let s = top.superlayer { top = s }
        for l in top.sublayers ?? [] where l.name?.contains("capture backdrop") == true
            && hasFilter(l, "gaussianBlur") {
            l.setValue(0, forKeyPath: "filters.gaussianBlur.inputRadius")
        }
        return patch(root, strength)
    }

    private static func hasFilter(_ l: CALayer, _ name: String) -> Bool {
        (l.filters ?? []).contains { ($0 as AnyObject).value(forKey: "name") as? String == name }
    }

    private static func patch(_ l: CALayer, _ s: Double) -> Int {
        var count = 0
        if hasFilter(l, "glassBackground") {
            count += 1
            let k = "filters.glassBackground."
            func set(_ key: String, _ v: Any) { l.setValue(v, forKeyPath: k + key) }
            typealias T = GlassTuning
            set("inputBlurRadius", T.blur)
            for i in 0..<4 { set("inputBlurOpacity\(i)", T.blur > 0.05 ? 1 : 0) }
            set("inputFaceColorMatrixWhite", 1 - 0.2 * T.lightBG)
            set("inputFaceColorMatrixBlack", 0.1 * T.darkBG)
            set("inputFaceColorMatrixFillColor", clearFill)
            set("inputInnerRefractionAmount", -T.refraction * s)
            set("inputInnerRefractionHeight", T.bevel * s)
            set("inputOuterRefractionAmount", -T.outerRefraction * s)
            set("inputOuterRefractionHeight", T.outerBevel * s)
            set("inputRefractionDistance0", T.profile0)
            set("inputRefractionDistance1", T.profile1)
            set("inputKeyFillHighlightAmount", T.highlight)
            set("inputKeyFillHighlightAngle", T.highlightAngle * .pi / 180)
            set("inputAberrationAmount", T.aberration * s)
            set("inputAberrationHeight", T.bevel * s)
            set("inputAberrationOffset", 0)
            set("inputAberrationAngle", 0)
            // 흐림을 전제로 뒤 화면을 절반 해상도로 캡처한다. 흐림을 거의 껐으니 원래 해상도로.
            l.setValue(1.0, forKey: "scale")
            // 렌즈가 캡처 밖(빈 곳)을 읽으면 검은 무늬가 비친다. 렌즈가 닿는 거리(굴절 세기)만큼 둘레를 더 캡처한다.
            // 세기(s)와 상관없이 고정값이다: 프레임마다 바꾸면 캡처 영역이 매번 달라져서,
            // 유리가 한 프레임 어둡게 번쩍이던 현상의 원인으로 의심된다 (화면을 볼 수 없어 확정하지는 못했다).
            l.setValue(T.refraction + T.outerRefraction + 4, forKey: "marginWidth")
        }
        for c in l.sublayers ?? [] { count += patch(c, s) }
        return count
    }
}
