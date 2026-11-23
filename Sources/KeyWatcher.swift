import AppKit
import AudioToolbox
import CoreAudio

/// 음량·밝기·재생 같은 기능 키가 눌리는 걸 지켜본다.
/// 보기만 하고 가로채지 않는다: 키는 평소대로 시스템이 처리한다.
/// 기능 키 전용 이벤트와 Shift·⌘ 같은 보조 키의 눌림만 받는다. 글자·숫자 같은 일반 키 입력은 아예 받지 않는다.
/// (보조 키는 쓰지 않고 버린다. 기능 키 이벤트만 달라고 하면 시스템이 아무것도 보내 주지 않아서 같이 요청한다:
///  이 맥에서 확인함.)
/// 다른 앱으로 가는 키를 보는 일이라 손쉬운 사용 권한이 있어야 동작한다.
@MainActor
final class KeyWatcher {
    enum Action {
        case volumeUp, volumeDown, mute
        case brightnessUp, brightnessDown
        case keyLightUp, keyLightDown
        case playPause, next, previous
    }

    /// (어떤 키, 꾹 눌러서 반복 중인지)
    var onAction: ((Action, Bool) -> Void)?
    private var monitor: Any?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // 기능 키는 "시스템 정의" 이벤트의 8번 종류로 온다. data1에 키 번호와 눌림/뗌이 들어 있다.
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return }
        let code = (event.data1 & 0xFFFF_0000) >> 16
        let state = (event.data1 & 0xFF00) >> 8
        let isRepeat = (event.data1 & 0x1) == 1
        guard state == 0x0A else { return } // 누를 때만
        let action: Action
        switch code {
        case 0: action = .volumeUp
        case 1: action = .volumeDown
        case 7: action = .mute
        case 2: action = .brightnessUp
        case 3: action = .brightnessDown
        case 21: action = .keyLightUp
        case 22: action = .keyLightDown
        case 16: action = .playPause
        case 17, 19: action = .next       // 19: Apple 키보드의 ▶▶ (꾹 누르면 빨리 감기)
        case 18, 20: action = .previous   // 20: Apple 키보드의 ◀◀
        default: return
        }
        // 재생 계열은 꾹 눌러도 한 번만 알린다.
        if isRepeat, [.playPause, .next, .previous].contains(action) { return }
        onAction?(action, isRepeat)
    }
}

/// 지금 기본 출력 장치의 음량과 음소거 상태. (지금은 음소거 여부만 쓴다)
enum AudioState {
    /// 음량 조절이 안 되는 장치(HDMI 등)면 nil.
    static func read() -> (volume: Double, muted: Bool)? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }

        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }

        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) != noErr {
            muted = 0
        }
        return (Double(volume), muted != 0)
    }
}

/// Dock 자동 가리기가 켜지고 꺼지는 걸 지켜본다 (⌥⌘D든 Dock 메뉴든).
/// ⌥⌘D는 시스템이 먼저 가져가서 키 감시로는 보이지 않는다. 그래서 Dock 설정값이 바뀌는 걸 직접 지켜본다.
/// 설정값만 읽으므로 권한이 필요 없다.
@MainActor
final class DockWatcher: NSObject {
    /// 바뀐 뒤의 값 (true면 가려짐)
    var onChange: ((Bool) -> Void)?
    private let dock = UserDefaults(suiteName: "com.apple.dock")
    private var last: Bool?
    private var observing = false

    func start() {
        guard !observing, let dock else { return }
        last = dock.bool(forKey: "autohide")
        dock.addObserver(self, forKeyPath: "autohide", options: [], context: nil)
        observing = true
    }

    func stop() {
        guard observing else { return }
        dock?.removeObserver(self, forKeyPath: "autohide")
        observing = false
    }

    // 다른 프로세스가 바꾼 값의 알림은 아무 스레드로나 올 수 있어서 메인으로 넘긴다.
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let now = self.dock?.bool(forKey: "autohide"), now != self.last else { return }
                self.last = now
                self.onChange?(now)
            }
        }
    }
}
