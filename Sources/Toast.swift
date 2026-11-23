import AppKit
import QuartzCore
import SwiftUI

/// 화면 가운데에 둥근 유리 방울이 "퐁" 하고 퍼지며 아이콘을 띄웠다가, 방울째 메뉴바 아이콘으로 날아가
/// 메뉴바 윗면에 부딪혀 천장에 튄 물처럼 튀고(옆·아래로 튀는 방울들, 가운데서 솟는 물기둥) 스며든다.
/// 스플래시는 메뉴바 위에 그린다. 이 macOS에서는 메뉴바 바탕과 아이콘이 한 장의 창이라 그 사이에 끼울 수 없고,
/// 메뉴바보다 아래 층에 두면 바탕에 가려 메뉴바 밑에서부터만 보인다.
///
/// 유리 연출은 Rainpane(https://github.com/tansan7271/rainpane)의 클릭 물방울을 본떴다: 본 방울이 살짝 넘쳤다가
/// 자리 잡고, 가장자리에서 잔 방울이 튀어 나가 목으로 이어져 있다가 끊기며 사라진다. 유리를 그리는 방식도 같다
/// (아래 `GlassField`): 유리 조각을 뷰로 하나하나 만들어 숨겼다 보였다 하지 않고, "지금 있는 조각 목록"만
/// 넘기면 SwiftUI가 조각을 넣고 뺀다. AppKit 유리 뷰를 직접 숨겼다 보였다 했을 때는 유리가 어둡게 번쩍였다.
///
/// 떠 있는 동안 다시 부르면 처음부터 다시 그리지 않고 이어서 간다.
///  - 가운데 머무는 중: 본 방울이 움찔 줄었다가 다시 부풀고 잔 방울이 한 번 더 튄다 (연타하면 누를 때마다).
///  - 메뉴바로 날아가는 중, 같은 종류: 그 자리에서 가운데로 돌아오며 다시 커진다.
///  - 메뉴바로 날아가는 중, 다른 종류: 날아가던 건 끝까지 가게 두고 가운데에 새 방울이 생긴다.
///
/// 가볍게 유지하는 방법:
///  - 모양은 연출이 도는 동안만 화면 주사율에 맞춰 갱신하고, 끝나면 갱신기를 멈춘다.
///  - 창은 화면 전체가 아니라 연출이 지나가는 영역만 덮는다.
///  - 도착 위치는 띄울 때 한 번만 읽는다.
///  - 끝나면 창·유리·아이콘 그림을 전부 버린다. 평소에는 아무것도 쥐고 있지 않는다.
///  - 도중에 잠자기·화면 꺼짐·데스크탑(Space) 전환·화면 구성 변경이 오면 그 자리에서 바로 치운다.
///    마무리 예약은 맥이 잠든 동안 멈췄다가 깨어나면 실행되므로, 어떤 경우에도 창이 남지 않는다.
@MainActor
final class GlassToast: NSObject {
    enum Content: Equatable {
        case emoji(String)
        case symbol(String) // SF Symbols 이름
    }

    private static let holdTime: TimeInterval = 0.65    // 가운데 머무는 시간
    private static let flyTime: TimeInterval = 0.5      // 날아가는 시간
    private static let puddleTime: TimeInterval = 0.62  // 메뉴바에 닿아 튀고 스며드는 시간
    private static let plateSide: CGFloat = 200         // 본 방울(원) 지름
    private static let landScale: Double = 0.15         // 메뉴바에 닿을 때의 크기 비율 (지름 30)
    private static let mouthWidth: CGFloat = 124        // 닿아서 윗면에 붙어 옆으로 퍼지는 폭 (깔때기 입구)
    private static let funnelDepth: CGFloat = 28        // 깔때기가 물기둥 굵기로 좁아지기까지의 깊이
    private static let jetLength: CGFloat = 28          // 깔때기 밑으로 더 솟는 물기둥 길이
    private static let jetWidth: CGFloat = 12
    private static let overscan: CGFloat = 8            // 깔때기 윗변을 화면 밖으로 이만큼 넘겨서 테두리 없이 화면에 이어 붙인다
    private static let mergeDistance: CGFloat = 24      // 이 거리 안이면 유리끼리 액체처럼 이어진다
    private static let burstDelay: TimeInterval = 0.07  // 본 방울이 조금 퍼진 뒤에 잔 방울을 쏜다
    private static let pulseGap: TimeInterval = 0.06    // 이보다 촘촘한 재호출은 움찔·잔 방울 없이 아이콘만 바꾼다
    private static let blobSlots = 3                    // 동시에 떠 있을 수 있는 본 방울 (가운데 1 + 날아가는 중 2)
    private static let maxDrops = 16                    // 동시에 떠 있을 수 있는 잔 방울
    private static let debug = ProcessInfo.processInfo.environment["LIQUIDTOAST_DEBUG"] == "1"

    /// 본 방울 하나: 아이콘과 움직임 상태. 유리 모양은 매 프레임 `shape`·`pos`로 목록에 실어 보낸다.
    private final class Blob {
        let slot: Int
        let icon: CALayer
        var active = false
        var group = ""
        var content: Content?
        var k = 0.0                 // 크기 비율 (스프링)
        var v = 0.0                 // 그 속도
        var fs = 1.0                // 날아가며 줄어드는 비율
        var pos = CGPoint.zero      // 지금 중심
        var shape = CGSize.zero     // 지금 그려진 크기. 너무 작아 안 그릴 땐 .zero
        var flightOrigin = CGPoint.zero
        var puddleStart: CGFloat?   // 메뉴바에 닿는 순간의 지름. nil이면 아직 안 닿음
        var funnel: GlassPiece.Funnel? // 메뉴바에 닿은 뒤의 깔때기 모양. nil이면 원(또는 알약)
        var jetTipFired = false     // 물기둥 끝에서 방울이 떨어져 나갔는지
        var appearAt: CFTimeInterval = 0
        var holdUntil: CFTimeInterval = 0
        var lastPulse: CFTimeInterval = 0
        var burstAt: CFTimeInterval?
        var burstCount = 5...7

        init(slot: Int, icon: CALayer) {
            self.slot = slot
            self.icon = icon
        }
    }

    /// 튀어 나가는 잔 방울 하나.
    private struct Drop {
        let id: Int
        let origin: CGPoint
        let direction: CGVector
        let from: CGFloat      // 출발 거리
        let travel: CGFloat    // 나가는 거리 (강한 ease-out으로 거의 멈출 때까지)
        let radius: CGFloat
        let birth: CFTimeInterval
        let life: TimeInterval
        var sag: CGFloat = 0   // 아래로 처지는 가속 (pt/s²). 메뉴바에서 튄 방울이 포물선으로 떨어지게
    }

    // 화면에 올린 것들 (떠 있는 동안만 존재)
    private var window: NSWindow?
    private var glassHost: NSView?
    private var glass: GlassModel?
    private var blobs: [Blob] = []
    /// 가운데 자리의 주인. 다시 부르면 이 방울이 이어 받는다.
    private var primary: Blob?
    private var drops: [Drop] = []
    private var nextDropID = 0
    private var link: CADisplayLink?
    private var safety: DispatchWorkItem?

    private var center = CGPoint.zero
    private var target = CGPoint.zero
    private var topY: CGFloat = 0       // 화면 윗변 (창 안 좌표)
    private var height: CGFloat = 0     // 창 높이 (SwiftUI의 위에서 아래로 가는 좌표로 바꿀 때 쓴다)
    private var backingScale: CGFloat = 2
    private var lastTick: CFTimeInterval = 0
    private var reduceMotion = false
    private var frameCount = 0
    /// 창을 띄울 때의 화면 배치. 이게 달라졌을 때만 "화면 구성이 바뀌었다"로 본다.
    private var screenLayout: [CGRect] = []

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(cancel), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// 이 알림은 모니터를 꽂거나 뺄 때뿐 아니라 Dock이 가려지거나 나타날 때도 온다 (쓸 수 있는 영역이 바뀌어서).
    /// Dock 토스트가 뜨자마자 이 알림에 치워지지 않도록, 화면 배치가 실제로 달라졌을 때만 치운다.
    @objc private func screensChanged() {
        if NSScreen.screens.map(\.frame) != screenLayout {
            tearDown()
        }
    }

    /// 아이콘을 띄운다. 이미 떠 있으면 이어서 간다 (규칙은 맨 위 설명 참고).
    /// - group: 같은 종류끼리 묶는 이름. 날아가던 방울을 다시 불러들일지, 새로 띄울지를 가른다.
    func show(_ content: Content, group: String, flyingTo statusButton: NSStatusBarButton?) {
        let statusFrame = statusButton?.window?.frame
        guard let screen = statusButton?.window?.screen ?? NSScreen.main else { return }
        // 화면 좌표로 출발점(화면 가운데)과 도착점(메뉴바 아이콘)을 잡는다. 아이콘을 못 읽으면 오른쪽 위 구석으로.
        let full = screen.frame
        let start = CGPoint(x: full.midX, y: full.midY)
        var end = CGPoint(x: full.maxX - 120, y: full.maxY - 16)
        if let statusFrame, full.intersects(statusFrame) {
            end = CGPoint(x: statusFrame.midX, y: statusFrame.midY)
        }
        // 창은 화면 전체가 아니라 연출이 지나가는 영역만 덮는다 (투명 창도 넓을수록 화면 합성 부담이 크다):
        // 가운데 둘레(잔 방울이 닿는 데까지) + 가운데에서 아이콘까지 가는 길 + 아이콘 둘레.
        let reach = Self.plateSide * 1.3
        let lane = Self.plateSide * 0.6
        let frame = CGRect(x: start.x - reach, y: start.y - reach, width: reach * 2, height: reach * 2)
            .union(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -lane, dy: -lane))
            .union(CGRect(x: end.x - 140, y: end.y - 150, width: 280, height: 210)) // 아이콘 아래로 튀는 범위
            .intersection(full).integral
        if let window, window.frame != frame {
            tearDown() // 다른 화면으로 옮겨 갔거나 아이콘 자리가 바뀌었으면 새로 시작
        }
        let fresh = (window == nil)
        build(frame: frame)
        guard let window else { return }
        if fresh {
            screenLayout = NSScreen.screens.map(\.frame)
        }

        // 이하 좌표는 전부 창 안 좌표 (왼쪽 아래가 원점).
        center = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
        target = CGPoint(x: end.x - frame.minX, y: end.y - frame.minY)
        topY = full.maxY - frame.minY
        height = frame.height
        backingScale = screen.backingScaleFactor

        let now = CACurrentMediaTime()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // 이어 받을 방울을 고른다.
        var blob = primary.flatMap { $0.active ? $0 : nil }
        if let current = blob, now >= current.holdUntil, current.group != group,
           hypot(current.pos.x - center.x, current.pos.y - center.y) > Self.plateSide * 0.6 {
            // 다른 종류가 이미 가운데를 떠나 날아가는 중: 그건 끝까지 가게 두고 새로 띄운다.
            blob = nil
        }

        if let blob {
            // 지금 보이는 크기와 자리에서 이어 간다.
            if blob.puddleStart != nil { blob.v = 0 }
            blob.k = Double(min(blob.shape.width, blob.shape.height) / Self.plateSide)
            blob.fs = 1
            blob.puddleStart = nil
            blob.funnel = nil
            blob.jetTipFired = false
            if now - blob.lastPulse > Self.pulseGap {
                if blob.k > 0.6 { blob.v = -9 } // 다 퍼져 있었으면 움찔 줄었다가 다시 부푼다
                // 연타 중에는 잔 방울을 조금씩만 쏜다 (매번 다 쏘면 금세 한도가 차서 뒤 연타는 아무것도 못 쏜다).
                blob.burstCount = now - blob.lastPulse < 0.3 ? 2...3 : 5...7
                blob.burstAt = now + Self.burstDelay
                blob.lastPulse = now
            }
        } else {
            // 빈 자리에 새로. 자리가 없으면 가장 먼저 떠난 방울을 거둬 쓴다.
            let fresh = blobs.first { !$0.active }
                ?? blobs.filter { $0 !== primary }.min { $0.holdUntil < $1.holdUntil }
                ?? blobs[0]
            fresh.active = true
            fresh.k = 0; fresh.v = 0; fresh.fs = 1
            fresh.pos = center
            fresh.shape = .zero
            fresh.puddleStart = nil
            fresh.funnel = nil
            fresh.jetTipFired = false
            fresh.appearAt = now
            fresh.lastPulse = now
            fresh.burstAt = now + Self.burstDelay
            fresh.burstCount = 5...7
            blob = fresh
        }
        guard let blob else { return }
        primary = blob
        blob.group = group
        setIcon(content, on: blob)
        if reduceMotion {
            blob.k = 1; blob.v = 0
            blob.pos = center
            blob.burstAt = nil
        }
        blob.holdUntil = now + Self.holdTime

        if link == nil {
            lastTick = now
        }
        layout(at: now, dt: 0)
        // 처음 띄울 때만 앞으로 올린다 (떠 있는 창을 누를 때마다 다시 올릴 이유가 없다).
        if fresh {
            window.orderFrontRegardless()
        }

        if link == nil, let view = window.contentView {
            let link = view.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        // 갱신기가 어떤 이유로든 끝까지 못 돌았을 때를 위한 마무리 예약.
        safety?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tearDown() }
        }
        safety = item
        let whole = Self.holdTime + Self.flyTime + Self.puddleTime
        DispatchQueue.main.asyncAfter(deadline: .now() + whole + 0.6, execute: item)
    }

    /// 진행 중인 연출을 즉시 중단하고 전부 치운다. 떠 있는 게 없으면 아무 일도 안 한다.
    @objc func cancel() {
        tearDown()
    }

    // MARK: 매 프레임

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.05)
        lastTick = now
        layout(at: now, dt: dt)
    }

    /// 지금 시각의 본 방울들·잔 방울·아이콘을 놓는다. 전부 끝났으면 치운다.
    private func layout(at now: CFTimeInterval, dt: TimeInterval) {
        guard let glass, let glassHost else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var pieces: [GlassPiece] = []
        var thickest: CGFloat = 0
        for blob in blobs where blob.active {
            guard advance(blob, now: now, dt: dt) else {
                retire(blob)
                continue
            }
            guard blob.shape != .zero else { continue }
            thickest = max(thickest, min(blob.shape.width, blob.shape.height))
            pieces.append(piece(id: blob.slot, center: blob.pos, size: blob.shape, funnel: blob.funnel))
        }

        // 잔 방울: 강한 ease-out으로 바깥으로 퍼지다 거의 멈추고, 수명 끝으로 갈수록 빠르게 작아진다.
        drops.removeAll { now - $0.birth >= $0.life }
        for drop in drops {
            let age = now - drop.birth
            let p = age / drop.life
            let r = drop.radius * CGFloat(min(1, max(0, age) / 0.05).squareRoot() * (1 - pow(p, 2.2)))
            guard r >= 0.5 else { continue }
            let distance = drop.from + drop.travel * CGFloat(1 - pow(1 - p, 5))
            pieces.append(piece(id: drop.id,
                                center: CGPoint(x: drop.origin.x + drop.direction.dx * distance,
                                                y: drop.origin.y + drop.direction.dy * distance
                                                    - drop.sag * CGFloat(age * age)),
                                size: CGSize(width: r * 2, height: r * 2)))
        }
        CATransaction.commit()

        // 본 방울이 다 끝나고 튄 방울까지 사라지면 치운다.
        guard blobs.contains(where: \.active) || !drops.isEmpty else {
            tearDown()
            return
        }

        // 조각 목록을 넘기면 SwiftUI가 유리를 다시 짠다. 그때마다 시스템이 유리 값을 새로 계산해 넣으므로,
        // 바로 레이아웃을 돌린 뒤 우리 값으로 덮어써야 이번 프레임에 남는다 (Rainpane과 같은 순서).
        // 렌즈 세기는 가장 큰 방울에 맞춘다. 지름 100 밑으로 작아지면 그만큼 약하게
        // (작은 모양에 큰 방울용 굴절을 걸면 엉뚱한 곳이 비친다). 가운데에서 움찔거리는 동안은 바뀌지 않는다.
        if glass.pieces != pieces {
            glass.pieces = pieces
        }
        glassHost.layoutSubtreeIfNeeded()
        let strength = Double(min(1, max(0.15, thickest / (Self.plateSide / 2))))
        var patched = 0
        if let layer = glassHost.layer {
            patched = GlassPatch.apply(layer, strength: strength)
        }
        if Self.debug, frameCount % 6 == 0 {
            let log = blobs.filter(\.active).map {
                String(format: "[%@ %.0f×%.0f @(%.0f, %.0f)]", $0.group, $0.shape.width, $0.shape.height, $0.pos.x, $0.pos.y)
            }.joined(separator: " ")
            print("  본 방울 \(log), 유리 조각 \(pieces.count)개, 유리 필터 \(patched)개")
        }
        frameCount += 1
    }

    /// 창 안 좌표(왼쪽 아래 원점)의 모양 하나를 SwiftUI 좌표(왼쪽 위 원점)의 유리 조각으로.
    private func piece(id: Int, center: CGPoint, size: CGSize, funnel: GlassPiece.Funnel? = nil) -> GlassPiece {
        GlassPiece(id: id, center: CGPoint(x: center.x, y: height - center.y), size: size, funnel: funnel)
    }

    /// 본 방울 하나를 dt만큼 진행시킨다. 수명이 끝났으면 false.
    private func advance(_ blob: Blob, now: CFTimeInterval, dt: TimeInterval) -> Bool {
        // 크기 스프링: 살짝 넘쳤다가 자리 잡는다. 발산하지 않게 잘게 나눠 적분한다.
        if !reduceMotion, dt > 0 {
            let steps = max(1, Int((dt * 240).rounded(.up)))
            let h = dt / Double(steps)
            let w = 24.0, z = 0.5
            for _ in 0..<steps {
                blob.v += ((1 - blob.k) * w * w - blob.v * 2 * z * w) * h
                blob.k = max(0, blob.k + blob.v * h)
            }
        }

        let arriveAt = blob.holdUntil + Self.flyTime
        let endAt = arriveAt + Self.puddleTime
        var size: CGSize
        var iconAlpha = 1.0

        if now < blob.holdUntil {
            // 가운데에 머문다 (날아가던 중에 다시 불렸으면 그 자리에서 가운데로 돌아온다).
            let a = dt > 0 ? 1 - exp(-dt / 0.06) : 0
            blob.pos.x += (center.x - blob.pos.x) * a
            blob.pos.y += (center.y - blob.pos.y) * a
            blob.flightOrigin = blob.pos
            let d = Self.plateSide * blob.k
            size = CGSize(width: d, height: d)
            iconAlpha = min(1, (now - blob.appearAt) / 0.1)
        } else if reduceMotion {
            return false // "동작 줄이기"면 날아가지 않고 그 자리에서 끝낸다
        } else if now < arriveAt {
            // 방울째 메뉴바 아이콘으로: 옆으로 먼저 흐르다가 아이콘 바로 아래에서 위로 솟는 곡선.
            let p = (now - blob.holdUntil) / Self.flyTime
            let e = pow(p, 1.8)
            let o = blob.flightOrigin
            let c = CGPoint(x: o.x + (target.x - o.x) * 0.9, y: o.y + (target.y - o.y) * 0.05)
            let u = 1 - e
            blob.pos = CGPoint(x: u * u * o.x + 2 * u * e * c.x + e * e * target.x,
                               y: u * u * o.y + 2 * u * e * c.y + e * e * target.y)
            blob.fs = 1 - (1 - Self.landScale) * e
            let d = Self.plateSide * blob.k * blob.fs
            size = CGSize(width: d, height: d)
            iconAlpha = p < 0.8 ? 1 : (1 - p) / 0.2
        } else if now < endAt {
            // 메뉴바 윗면에 부딪혔다. 천장에 튄 물처럼:
            //  1) 윗면에 달라붙어 옆으로 퍼진다. 가장자리는 화면 윗변에 스르르 이어지고 가운데로 갈수록
            //     오목하게 좁아지는 깔때기 모양 (윗면을 타고 번진 물이 가운데로 모여 늘어지는 모습)
            //  2) 부딪힌 자리에서 방울들이 부채꼴로 아래·옆으로 튀어 포물선으로 떨어진다 (왕관)
            //  3) 깔때기 끝이 물기둥으로 아래로 솟았다가, 끝에서 방울 하나가 떨어져 나가며 도로 빨려 올라간다
            //  4) 깔때기가 얕아지고 좁아지며 스며든다
            if blob.puddleStart == nil {
                blob.puddleStart = Self.plateSide * blob.k * Self.landScale
                splash(at: now)
            }
            let d0 = blob.puddleStart ?? 30
            let t = now - arriveAt
            let spread = 1 - exp(-t / 0.05)
            let fade = max(0, (t - 0.3) / (Self.puddleTime - 0.3))
            // 입구 폭과 깔때기 깊이: 닿는 순간의 방울 크기에서 시작해 퍼졌다가, 끝에 가서 줄어든다.
            let mouth = (d0 + (Self.mouthWidth - d0) * spread) * (1 - 0.5 * fade)
            let depth = (d0 * 0.9 + (Self.funnelDepth - d0 * 0.9) * spread) * (1 - fade * fade)
            // 물기둥: 0.05초 뒤부터 빠르게 솟고(0.2초), 잠깐 머물다, 0.3초부터 도로 올라간다.
            let rise = min(1, max(0, (t - 0.05) / 0.2))
            let fall = min(1, max(0, (t - 0.3) / 0.24))
            let jet = Self.jetLength * CGFloat((1 - pow(1 - rise, 3)) * (1 - fall * fall))
            let length = depth + jet
            blob.funnel = GlassPiece.Funnel(overscan: Self.overscan, depth: depth,
                                            stem: Self.jetWidth * CGFloat(1 - 0.4 * fade))
            // 윗변은 화면 윗변을 살짝 넘어가고(잘려서 테두리가 안 보인다), 아래 끝이 물기둥 끝이다.
            blob.pos = CGPoint(x: target.x, y: topY + (Self.overscan - length) / 2)
            size = depth < 3 ? .zero : CGSize(width: mouth, height: length + Self.overscan)
            iconAlpha = 0
            // 물기둥이 다 솟았을 때 끝에서 방울 하나가 떨어져 나간다 (기둥이 올라가면서 목이 끊긴다).
            if !blob.jetTipFired, t >= 0.22 {
                blob.jetTipFired = true
                addDrop(origin: CGPoint(x: target.x, y: topY - Self.funnelDepth - Self.jetLength + 4),
                        direction: CGVector(dx: 0, dy: -1),
                        from: 0, travel: 40, radius: 9, at: now, life: 0.42, sag: 160)
            }
        } else {
            return false
        }

        // 아주 작을 땐 점처럼 남지 않게 그리지 않는다.
        blob.shape = min(size.width, size.height) < 4 ? .zero : size

        if let at = blob.burstAt, now >= at {
            blob.burstAt = nil
            burst(from: blob, at: now)
        }

        blob.icon.position = blob.pos
        blob.icon.opacity = Float(max(0, min(1, iconAlpha)))
        let iconScale = CGFloat(min(blob.k, 1.3) * blob.fs)
        blob.icon.setAffineTransform(CGAffineTransform(scaleX: iconScale, y: iconScale))
        return true
    }

    private func retire(_ blob: Blob) {
        blob.active = false
        blob.icon.opacity = 0
        blob.icon.contents = nil
        blob.content = nil
        blob.shape = .zero
        blob.burstAt = nil
        blob.puddleStart = nil
        blob.funnel = nil
        blob.jetTipFired = false
        if primary === blob {
            primary = nil
        }
    }

    // MARK: 잔 방울

    /// 본 방울 둘레에 고르게(조금씩 흐트러뜨려) 잔 방울을 쏜다. 대부분 작고 가끔 크다.
    private func burst(from blob: Blob, at now: CFTimeInterval) {
        let n = Int.random(in: blob.burstCount)
        let rest = Self.plateSide / 2
        // 본 방울이 아직 작으면 곧 퍼질 가장자리에서 쏜다.
        let rim = max(Self.plateSide * CGFloat(blob.k) / 2, rest * 0.32)
        let a0 = Double.random(in: 0..<(2 * .pi))
        for i in 0..<n {
            let a = a0 + Double(i) / Double(n) * 2 * .pi + Double.random(in: -0.45...0.45)
            let radius = Self.plateSide * CGFloat(0.06 + 0.15 * pow(Double.random(in: 0...1), 1.8))
            let from = max(0, rim - radius) * 0.85
            let stop = rest + radius + Self.mergeDistance * CGFloat.random(in: 0.3...2.0)
            addDrop(origin: blob.pos, direction: CGVector(dx: cos(a), dy: sin(a)), from: from,
                    travel: max(4, stop - from), radius: radius, at: now, life: Double.random(in: 0.5...0.8))
        }
    }

    /// 메뉴바에 부딪히는 순간 부채꼴로 튀는 방울들 (왕관). 옆으로 눕는 것일수록 멀리 가고,
    /// 다 같이 포물선으로 떨어지며 작아진다. 밑동 가까이에서는 목으로 이어져 있다가 끊긴다.
    private func splash(at now: CFTimeInterval) {
        let origin = CGPoint(x: target.x, y: topY - 8)
        // 양쪽 세 방향씩 여섯 중에서 한두 개를 빼서 4~5개만 쏜다 (매번 다른 쪽이 빈다).
        var angles = [-78.0, -52.0, -26.0, 26.0, 52.0, 78.0]
        angles.remove(at: Int.random(in: 0..<3))
        if Bool.random() {
            angles.remove(at: Int.random(in: 2..<5))
        }
        for base in angles {
            // 각도는 똑바로 아래가 0도, 양옆이 ±90도.
            let a = (base + Double.random(in: -9...9)) * .pi / 180
            let sideways = abs(sin(a))
            addDrop(origin: origin, direction: CGVector(dx: sin(a), dy: -cos(a)), from: 8,
                    travel: CGFloat(42 + 46 * sideways) * CGFloat.random(in: 0.8...1.15),
                    radius: CGFloat.random(in: 6...12) * CGFloat(1.1 - 0.25 * sideways),
                    at: now, life: Double.random(in: 0.38...0.58), sag: 130)
        }
    }

    private func addDrop(origin: CGPoint, direction: CGVector, from: CGFloat, travel: CGFloat,
                         radius: CGFloat, at now: CFTimeInterval, life: TimeInterval, sag: CGFloat = 0) {
        // 한도가 차 있으면 이 방울은 건너뛴다 (연타해도 방울 수가 늘지 않는다).
        guard drops.count < Self.maxDrops else { return }
        nextDropID += 1
        // 본 방울 번호(0…2)와 겹치지 않게 100부터.
        drops.append(Drop(id: 100 + nextDropID, origin: origin, direction: direction, from: from,
                          travel: travel, radius: radius, birth: now, life: life, sag: sag))
    }

    // MARK: 아이콘

    private func setIcon(_ content: Content, on blob: Blob) {
        guard content != blob.content || blob.icon.contents == nil else { return }
        blob.content = content
        let image: NSImage
        var isSymbol = false
        switch content {
        case .emoji(let text):
            image = Self.emojiImage(text)
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 84, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                // 레이어에 올릴 수 있게 그림 한 장으로 굳힌다.
                image = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    return true
                }
                isSymbol = true
            } else {
                image = Self.emojiImage("❔")
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let icon = blob.icon
        icon.contents = image.layerContents(forContentsScale: backingScale)
        icon.contentsScale = backingScale
        icon.bounds = CGRect(origin: .zero, size: image.size)
        // 흰 기호는 밝은 화면 위에서 묻히지 않게 그림자를 연하게 두른다. 이모지는 제 색이 있어 필요 없다.
        icon.shadowOpacity = isSymbol ? 0.28 : 0
        icon.shadowRadius = 8
        icon.shadowOffset = .zero
        CATransaction.commit()
    }

    private static func emojiImage(_ text: String) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 110)])
        return NSImage(size: string.size(), flipped: false) { _ in
            string.draw(at: .zero)
            return true
        }
    }

    // MARK: 만들기 / 정리

    private func tearDown() {
        safety?.cancel()
        safety = nil
        link?.invalidate()
        link = nil
        for blob in blobs {
            blob.icon.contents = nil
        }
        glass?.pieces = []
        window?.orderOut(nil)
        window?.contentView = nil
        blobs = []
        primary = nil
        drops = []
        glass = nil
        glassHost = nil
        window = nil
    }

    /// 창이 없으면 만든다. 이미 떠 있으면 그대로 다시 쓴다. frame은 화면 좌표.
    private func build(frame: CGRect) {
        guard window == nil else { return }
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none // 내릴 때 시스템이 붙이는 창 닫힘 연출 없이 바로 사라지게
        window.ignoresMouseEvents = true // 클릭은 전부 아래 창으로 통과
        // 전체 화면 앱이나 화면 가림막보다도 위에 뜨도록 가림막 층보다 한 층 위.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bounds = NSRect(origin: .zero, size: frame.size)
        let root = NSView(frame: bounds)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        // 유리 층: 조각 목록을 그리는 SwiftUI 뷰 하나.
        let glass = GlassModel()
        let host = NSHostingView(rootView: GlassField(model: glass, spacing: Self.mergeDistance))
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)

        // 아이콘은 유리 위에 얹은 별도 층에 둔다.
        let stage = NSView(frame: bounds)
        stage.autoresizingMask = [.width, .height]
        stage.layer = CALayer()
        stage.wantsLayer = true
        root.addSubview(stage)

        window.contentView = root
        self.window = window
        self.glass = glass
        self.glassHost = host
        self.blobs = (0..<Self.blobSlots).map { slot in
            let icon = CALayer()
            icon.opacity = 0
            stage.layer?.addSublayer(icon)
            return Blob(slot: slot, icon: icon)
        }
        self.primary = nil
        self.drops = []
        frameCount = 0
    }
}

// MARK: - 유리 층 (SwiftUI)

/// 유리 조각 하나. 보통은 원(가로세로가 다르면 양 끝이 둥근 알약)이고, funnel이 있으면 깔때기 모양이다.
/// 좌표는 SwiftUI식(왼쪽 위 원점, y는 아래로).
struct GlassPiece: Identifiable, Equatable {
    let id: Int
    var center: CGPoint
    var size: CGSize
    var funnel: Funnel? = nil

    /// 천장(화면 윗변)에 매달린 깔때기. 조각의 윗변이 천장 쪽, 아랫변이 물기둥 끝.
    struct Funnel: Equatable {
        var overscan: CGFloat  // 천장 위로 넘겨 그리는 높이 (화면 밖이라 잘린다)
        var depth: CGFloat     // 천장에서 물기둥 굵기로 좁아지기까지의 깊이
        var stem: CGFloat      // 물기둥 굵기
    }
}

/// 조각의 외곽선.
struct PieceShape: Shape {
    let funnel: GlassPiece.Funnel?

    func path(in rect: CGRect) -> Path {
        guard let funnel else {
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        }
        // 깔때기: 입구 양 끝은 천장에 스르르 붙고(접선이 수평), 가운데로 오목하게 좁아져 물기둥이 되고,
        // 물기둥 끝은 둥글다.
        let ceiling = rect.minY + funnel.overscan
        let stem = min(funnel.stem, rect.width) / 2
        let tip = rect.maxY
        // 물기둥이 아직 없거나 다 올라갔으면 깔때기가 곧장 둥근 끝으로 닫힌다.
        let neck = min(ceiling + funnel.depth, max(ceiling + 1, tip - stem))
        let cx = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: ceiling))
        path.addCurve(to: CGPoint(x: cx - stem, y: neck),
                      control1: CGPoint(x: rect.minX + (cx - stem - rect.minX) * 0.6, y: ceiling),
                      control2: CGPoint(x: cx - stem, y: ceiling + (neck - ceiling) * 0.45))
        path.addLine(to: CGPoint(x: cx - stem, y: tip - stem))
        path.addArc(center: CGPoint(x: cx, y: tip - stem), radius: stem,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: cx + stem, y: neck))
        path.addCurve(to: CGPoint(x: rect.maxX, y: ceiling),
                      control1: CGPoint(x: cx + stem, y: ceiling + (neck - ceiling) * 0.45),
                      control2: CGPoint(x: rect.maxX - (rect.maxX - cx - stem) * 0.6, y: ceiling))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

final class GlassModel: ObservableObject {
    @Published var pieces: [GlassPiece] = []
}

/// 조각 목록을 리퀴드 글래스로 그린다. 한 컨테이너 안의 유리끼리는 가까우면 액체처럼 이어진다.
struct GlassField: View {
    @ObservedObject var model: GlassModel
    let spacing: CGFloat

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(model.pieces) { piece in
                    Color.clear
                        .frame(width: piece.size.width, height: piece.size.height)
                        .glassEffect(.clear, in: PieceShape(funnel: piece.funnel))
                        .position(piece.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
