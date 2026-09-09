import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import CoreGraphics
import Darwin
import UniformTypeIdentifiers

// MARK: - 数据模型

struct SelectedApp: Codable, Equatable {
    var originalPath: String
    var copyPath: String

    var originalURL: URL { URL(fileURLWithPath: originalPath) }
    var copyURL: URL { URL(fileURLWithPath: copyPath) }

    var displayName: String {
        Bundle(url: originalURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: originalURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? originalURL.deletingPathExtension().lastPathComponent
    }
}

// MARK: - 核心逻辑：制作并启动隐藏副本

enum HiddenAppManager {
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("隐藏工具/Hidden Apps", isDirectory: true)
    }

    static func storedApps() -> [SelectedApp] {
        guard let data = UserDefaults.standard.data(forKey: "selectedApps"),
              let apps = try? JSONDecoder().decode([SelectedApp].self, from: data) else {
            return []
        }
        return apps
    }

    static func save(_ apps: [SelectedApp]) {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: "selectedApps")
        }
    }

    static func remove(_ app: SelectedApp) {
        var apps = storedApps()
        apps.removeAll { $0.originalPath == app.originalPath }
        save(apps)
    }

    static func copyURL(for originalURL: URL) -> URL {
        let name = originalURL.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: originalURL)?.bundleIdentifier ?? "app"
        let safeID = bundleID.replacingOccurrences(of: "/", with: "_")
        return supportRoot.appendingPathComponent("\(name)-\(safeID).app")
    }

    /// 复制原软件 → 去掉隔离标记 → 加上“菜单栏应用”标记 → 重新签名。
    static func makeHiddenCopy(of originalURL: URL) throws -> URL {
        let dest = copyURL(for: originalURL)
        let fm = FileManager.default
        try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: originalURL, to: dest)

        stripQuarantine(at: dest)

        let plistURL = dest.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        plist["LSUIElement"] = true
        let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try newData.write(to: plistURL)

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--deep", "--sign", "-", dest.path]
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw NSError(domain: "HiddenTools", code: 3, userInfo: [NSLocalizedDescriptionKey: "隐藏副本重新签名失败"])
        }
        return dest
    }

    private static func stripQuarantine(at url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    static func runningCopy(of entry: SelectedApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { isHiddenCopy($0, of: entry) }
    }

    /// 所有运行中的“隐藏副本”（按可执行文件所在目录判断，不依赖已保存列表）。
    static func runningHiddenCopies() -> [NSRunningApplication] {
        let prefix = supportRoot.standardizedFileURL.path + "/"
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let execPath = app.executableURL?.standardizedFileURL.path else { return false }
            return execPath.hasPrefix(prefix)
        }
    }

    /// 已保存列表 + 自动补全正在运行的隐藏副本（并持久化）。
    static func knownApps() -> [SelectedApp] {
        var apps = storedApps()
        var changed = false
        for app in runningHiddenCopies() {
            guard let bundleURL = app.bundleURL else { continue }
            let path = bundleURL.standardizedFileURL.path
            if !apps.contains(where: { $0.copyURL.standardizedFileURL.path == path }) {
                apps.append(SelectedApp(originalPath: path, copyPath: path))
                changed = true
            }
        }
        if changed {
            save(apps)
        }
        return apps
    }

    static func launchHidden(_ entry: SelectedApp, completion: @escaping (NSRunningApplication?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: entry.copyURL, configuration: config) { app, _ in
            DispatchQueue.main.async {
                if let app = app {
                    // 等窗口创建后隐藏，保持“只留状态栏图标”的效果
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        hideHiddenCopy(app)
                    }
                }
                completion(app)
            }
        }
    }
}

// MARK: - 辅助功能（隐藏其它应用的窗口）

enum AXHelper {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统官方的辅助功能授权弹窗。
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 通过辅助功能接口隐藏/显示某个应用的全部窗口。
    @discardableResult
    static func setHidden(_ hidden: Bool, forPID pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        let value: CFBoolean = hidden ? kCFBooleanTrue : kCFBooleanFalse
        let error = AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, value)
        return error == .success
    }
}

// MARK: - 单应用静音（Core Audio 进程截获 + 聚合设备接管，macOS 14.2+）

@available(macOS 14.2, *)
final class AudioMuteManager {
    static let shared = AudioMuteManager()

    private let lock = NSLock()
    private var sessions: [pid_t: Session] = [:]

    struct Session {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID?
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// 把指定进程设为静音（重复调用幂等）。
    @discardableResult
    func mute(pid: pid_t) -> Bool {
        lock.lock()
        let already = sessions[pid] != nil
        lock.unlock()
        if already { return true }

        guard let session = createSession(for: pid) else { return false }
        lock.lock()
        sessions[pid] = session
        lock.unlock()
        return true
    }

    /// 恢复指定进程的声音。
    func unmute(pid: pid_t) {
        lock.lock()
        let session = sessions.removeValue(forKey: pid)
        lock.unlock()
        if let session = session {
            destroy(session)
        }
    }

    /// 恢复所有被静音的进程（工具退出时调用，避免留下静音状态）。
    func unmuteAll() {
        lock.lock()
        let all = sessions
        sessions.removeAll()
        lock.unlock()
        for (_, session) in all {
            destroy(session)
        }
    }

    /// 清理已退出进程留下的静音会话。
    func pruneDeadSessions() {
        lock.lock()
        let dead = sessions.filter { kill($0.key, 0) != 0 }
        for pid in dead.keys {
            sessions.removeValue(forKey: pid)
        }
        lock.unlock()
        for (_, session) in dead {
            destroy(session)
        }
    }

    // MARK: 创建 / 销毁

    private func createSession(for pid: pid_t) -> Session? {
        guard let processObjectID = processObjectID(for: pid) else { return nil }

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        let tapUUID = UUID()
        tapDesc.uuid = tapUUID
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.isPrivate = true
        tapDesc.name = "隐藏工具-静音"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr else { return nil }

        guard let outputDeviceID = defaultOutputDeviceID(),
              let outputUID = deviceUID(outputDeviceID) else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let transport = transportType(outputDeviceID)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                       || transport == kAudioDeviceTransportTypeBluetoothLE

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "隐藏工具-\(pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: isBluetooth,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        guard waitForDeviceReady(aggregateID, timeout: 3.0) else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // 让聚合设备的采样率/缓冲与当前输出设备一致
        if let outRate = sampleRate(outputDeviceID) {
            let aggRate = sampleRate(aggregateID)
            if aggRate != outRate {
                setSampleRate(aggregateID, sampleRate: outRate)
                CFRunLoopRunInMode(.defaultMode, 0.1, false)
            }
        }
        let outBuffer = bufferFrameSize(outputDeviceID)
        let aggBuffer = bufferFrameSize(aggregateID)
        if outBuffer > 0, aggBuffer != outBuffer {
            setBufferFrameSize(aggregateID, size: outBuffer)
        }

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, _, _, outOutputData, _ in
            // 静音：输出全零
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buffer in output {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }
        guard createStatus == noErr, let procID = procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        guard AudioDeviceStart(aggregateID, procID) == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        return Session(tapID: tapID, aggregateID: aggregateID, procID: procID)
    }

    private func destroy(_ session: Session) {
        if let procID = session.procID {
            AudioDeviceStop(session.aggregateID, procID)
            AudioDeviceDestroyIOProcID(session.aggregateID, procID)
        }
        AudioHardwareDestroyAggregateDevice(session.aggregateID)
        AudioHardwareDestroyProcessTap(session.tapID)
    }

    // MARK: CoreAudio 辅助

    private func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        return (status == noErr && objectID != AudioObjectID(kAudioObjectUnknown)) ? objectID : nil
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return (status == noErr && deviceID != AudioObjectID(kAudioObjectUnknown)) ? deviceID : nil
    }

    private func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? uid as String : nil
    }

    private func transportType(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    private func sampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    private func setSampleRate(_ deviceID: AudioObjectID, sampleRate: Float64) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
    }

    private func bufferFrameSize(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value
    }

    private func setBufferFrameSize(_ deviceID: AudioObjectID, size bufferSize: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = bufferSize
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func waitForDeviceReady(_ deviceID: AudioObjectID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive) == noErr,
               isAlive != 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

private var screenPermissionPromptShown = false

@available(macOS 14.2, *)
func ensureScreenRecordingPermission() {
    guard !screenPermissionPromptShown else { return }
    screenPermissionPromptShown = true
    guard !AudioMuteManager.screenRecordingGranted else { return }

    AudioMuteManager.requestScreenRecording()
    let alert = NSAlert()
    alert.messageText = "需要屏幕与系统音频录制权限"
    alert.informativeText = "为了能单独静音软件的声音，请到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中勾选“隐藏工具”，然后重新打开一次工具。"
    alert.addButton(withTitle: "打开系统设置")
    alert.addButton(withTitle: "稍后再说")
    if alert.runModal() == .alertFirstButtonReturn {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

func muteApp(_ pid: pid_t) {
    if #available(macOS 14.2, *) {
        AudioMuteManager.shared.mute(pid: pid)
    }
}

func unmuteApp(_ pid: pid_t) {
    if #available(macOS 14.2, *) {
        AudioMuteManager.shared.unmute(pid: pid)
    }
}

func unmuteAllApps() {
    if #available(macOS 14.2, *) {
        AudioMuteManager.shared.unmuteAll()
    }
}

func pruneMuteSessions() {
    if #available(macOS 14.2, *) {
        AudioMuteManager.shared.pruneDeadSessions()
    }
}

/// 列出某个应用包路径下所有正在运行的进程（主进程 + Helper/渲染进程等）。
func processesUnder(path: String) -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count))
    let actual = proc_listallpids(&pids, count)
    guard actual > 0 else { return [] }

    let prefix = path + "/"
    var result: [pid_t] = []
    for i in 0..<Int(actual) {
        let pid = pids[i]
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if len > 0 {
            let execPath = String(cString: buffer)
            if execPath.hasPrefix(prefix) {
                result.append(pid)
            }
        }
    }
    return result
}

/// 静音某个隐藏副本的全部进程（覆盖 Electron 等含辅助进程的软件）。
func muteAppBundle(_ app: NSRunningApplication) {
    if #available(macOS 14.2, *) {
        ensureScreenRecordingPermission()
    }
    var pids = Set<pid_t>([app.processIdentifier])
    if let path = app.bundleURL?.path {
        pids.formUnion(processesUnder(path: path))
    }
    for pid in pids {
        muteApp(pid)
    }
}

/// 恢复某个隐藏副本全部进程的声音。
func unmuteAppBundle(_ app: NSRunningApplication) {
    var pids = Set<pid_t>([app.processIdentifier])
    if let path = app.bundleURL?.path {
        pids.formUnion(processesUnder(path: path))
    }
    for pid in pids {
        unmuteApp(pid)
    }
}

/// 判断一个运行中的应用是不是某个隐藏副本（按可执行文件路径匹配，比 bundle 路径更可靠）。
func isHiddenCopy(_ app: NSRunningApplication, of entry: SelectedApp) -> Bool {
    let copyPrefix = entry.copyURL.standardizedFileURL.path + "/"
    if let execPath = app.executableURL?.standardizedFileURL.path,
       execPath.hasPrefix(copyPrefix) {
        return true
    }
    return app.bundleURL?.standardizedFileURL.path == entry.copyURL.standardizedFileURL.path
}

/// 隐藏一个隐藏副本的窗口并单独静音。
func hideHiddenCopy(_ app: NSRunningApplication) {
    let axOK = AXHelper.setHidden(true, forPID: app.processIdentifier)
    let fallback = axOK ? true : app.hide()
    print("HIDE -> \(app.bundleURL?.path ?? "?") ax=\(axOK) fallback=\(fallback)")
    muteAppBundle(app)
}

/// 显示一个隐藏副本的窗口并恢复声音。
func showHiddenCopy(_ app: NSRunningApplication, activate: Bool) {
    AXHelper.setHidden(false, forPID: app.processIdentifier)
    app.unhide()
    if activate {
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
    unmuteAppBundle(app)
}

/// 把所有“隐藏副本”的窗口全部隐藏并静音。
func hideAllHiddenAppWindows() {
    for app in HiddenAppManager.runningHiddenCopies() {
        hideHiddenCopy(app)
    }
}

/// 把所有“隐藏副本”的窗口全部恢复显示并恢复声音。
func showAllHiddenAppWindows() {
    for app in HiddenAppManager.runningHiddenCopies() {
        showHiddenCopy(app, activate: false)
    }
}

// MARK: - 全局快捷键（一键快速隐藏）

final class PanicHotkey {
    static let shared = PanicHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x48494445), id: 1)
    private var action: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData = userData else { return noErr }
            let hotkey = Unmanaged<PanicHotkey>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr, hotKeyID.id == hotkey.hotKeyID.id {
                DispatchQueue.main.async { hotkey.action?() }
            }
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else { return }

        let id = hotKeyID
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("快速隐藏快捷键注册失败：\(registerStatus)")
        }
    }
}

// MARK: - 任意键双击检测（CGEvent 事件截获，使用已授权的辅助功能权限）

final class DoubleTapDetector {
    static let shared = DoubleTapDetector()

    private let lock = NSLock()
    private var lastKeyCode: Int64?
    private var lastTime: TimeInterval = 0
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onTrigger: (() -> Void)?
    private(set) var isRunning = false

    /// 两次按下之间的最大间隔（秒）。非常快速的双击通常小于 0.2 秒。
    private let doubleTapInterval: TimeInterval = 0.2

    func start(onTrigger: @escaping () -> Void) {
        guard !isRunning else { return }
        self.onTrigger = onTrigger

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let detector = Unmanaged<DoubleTapDetector>.fromOpaque(userInfo).takeUnretainedValue()
                detector.handle(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("双击检测启动失败（可能缺少辅助功能权限）")
            return
        }

        tap = newTap
        CGEvent.tapEnable(tap: newTap, enable: true)
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        isRunning = true
    }

    private func handle(_ event: CGEvent) {
        guard event.type == .keyDown else { return }
        // 跳过长按产生的自动重复，避免误触发
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        var shouldTrigger = false
        if keyCode == lastKeyCode, now - lastTime < doubleTapInterval {
            lastKeyCode = nil
            lastTime = 0
            shouldTrigger = true
        } else {
            lastKeyCode = keyCode
            lastTime = now
        }
        lock.unlock()

        if shouldTrigger {
            DispatchQueue.main.async { [weak self] in
                self?.onTrigger?()
            }
        }
    }
}

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var panicActive = false
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        createStatusItem()

        // 启动时自动补全正在运行的隐藏副本，保证菜单和快速隐藏都能找到它们。
        _ = HiddenAppManager.knownApps()

        // 任意键双击：非常快速地连按同一个键两次，触发快速隐藏/恢复
        DoubleTapDetector.shared.start { [weak self] in
            self?.togglePanic()
        }

        if let path = autoPanicTestPath {
            runAutoPanicTest(path: path)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkAccessibilityPermission()
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // 全局快捷键：⌃⌥⌘H 一键快速隐藏
        PanicHotkey.shared.register(
            keyCode: 4, // H
            modifiers: UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        ) { [weak self] in
            self?.togglePanic()
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏工具")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func checkAccessibilityPermission() {
        guard !AXHelper.isTrusted else { return }

        // 先触发系统官方授权弹窗（会明确列出“隐藏工具”）。
        _ = AXHelper.requestAccessibility()
        startTrustPolling()

        // 如果用户还没处理，稍后再给出手动引导。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, !AXHelper.isTrusted else { return }
            self.showPermissionGuide()
        }
    }

    private func showPermissionGuide() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "为了能一键隐藏软件窗口，请到「系统设置 → 隐私与安全性 → 辅助功能」中勾选“隐藏工具”。授权后需要重新打开一次工具。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    /// 授权后无需重启即可继续使用（若系统要求重启，重新打开工具即可）。
    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXHelper.isTrusted {
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                // 授权后自动恢复“任意键双击”监听
                DoubleTapDetector.shared.start { [weak self] in
                    self?.togglePanic()
                }
            }
        }
    }

    /// 自动验证模式：启动隐藏副本 → 触发快速隐藏 → 把结果写入 /tmp/panic_test_result.txt。
    private func runAutoPanicTest(path: String) {
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                let copyURL = try HiddenAppManager.makeHiddenCopy(of: url)
                let entry = SelectedApp(originalPath: url.path, copyPath: copyURL.path)
                var apps = HiddenAppManager.storedApps()
                apps.removeAll { $0.originalPath == url.path }
                apps.append(entry)
                HiddenAppManager.save(apps)

                var launched: NSRunningApplication?
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    NSWorkspace.shared.openApplication(at: copyURL, configuration: config) { app, _ in
                        launched = app
                        cont.resume()
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let before = visibleWindowCount(of: launched.map { Int($0.processIdentifier) } ?? -1)
                hideAllHiddenAppWindows()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let after = visibleWindowCount(of: launched.map { Int($0.processIdentifier) } ?? -1)
                let text = "AX_TRUSTED=\(AXHelper.isTrusted)\nTAP_CREATED=\(DoubleTapDetector.shared.isRunning)\nWINDOWS_BEFORE=\(before)\nWINDOWS_AFTER=\(after)\n"
                try? text.write(toFile: "/tmp/panic_test_result.txt", atomically: true, encoding: .utf8)
                HiddenAppManager.remove(entry)
                launched?.terminate()
            } catch {
                let text = "ERROR=\(error.localizedDescription)\n"
                try? text.write(toFile: "/tmp/panic_test_result.txt", atomically: true, encoding: .utf8)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func workspaceChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if note.name == NSWorkspace.didTerminateApplicationNotification {
            unmuteApp(app.processIdentifier)
        } else if note.name == NSWorkspace.didLaunchApplicationNotification,
                  panicActive,
                  HiddenAppManager.runningHiddenCopies().contains(where: { $0.processIdentifier == app.processIdentifier }) {
            // 快速隐藏状态下重新启动的隐藏副本：继续隐藏并静音
            hideHiddenCopy(app)
        }
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        pruneMuteSessions()

        let title = NSMenuItem(title: "隐藏工具", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let choose = NSMenuItem(title: "选择要隐藏的软件…", action: #selector(chooseApps), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let panicTitle = panicActive ? "恢复全部窗口和声音（⌃⌥⌘H）" : "快速隐藏并静音全部（⌃⌥⌘H）"
        let panic = NSMenuItem(title: panicTitle, action: #selector(togglePanic), keyEquivalent: "")
        panic.target = self
        menu.addItem(panic)

        let hint = NSMenuItem(title: "连按任意键两次，或按 ⌃⌥⌘H", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let apps = HiddenAppManager.knownApps()
        if apps.isEmpty {
            let empty = NSMenuItem(title: "还没有选择软件", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "已选择的软件", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in apps {
                menu.addItem(item(for: entry))
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出隐藏工具", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func item(for entry: SelectedApp) -> NSMenuItem {
        let item = NSMenuItem(title: entry.displayName, action: nil, keyEquivalent: "")
        item.image = NSWorkspace.shared.icon(forFile: entry.originalPath)
        item.image?.size = NSSize(width: 16, height: 16)
        item.representedObject = entry

        let sub = NSMenu()
        if let running = HiddenAppManager.runningCopy(of: entry) {
            item.state = .on
            addAction("显示窗口", #selector(showWindowAction(_:)), running, to: sub)
            addAction("隐藏窗口", #selector(hideWindowAction(_:)), running, to: sub)
            addAction("退出", #selector(terminateAction(_:)), running, to: sub)
        } else {
            let launch = NSMenuItem(title: "启动并隐藏", action: #selector(launchAction(_:)), keyEquivalent: "")
            launch.target = self
            launch.representedObject = entry
            sub.addItem(launch)
        }
        let remove = NSMenuItem(title: "从列表移除", action: #selector(removeAction(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = entry
        sub.addItem(remove)

        item.submenu = sub
        return item
    }

    private func addAction(_ title: String, _ selector: Selector, _ app: NSRunningApplication, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = app
        menu.addItem(item)
    }

    // MARK: 操作

    @objc private func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "选择要隐藏的软件"
        panel.prompt = "选择"
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addAndLaunch(url)
        }
    }

    private func addAndLaunch(_ url: URL) {
        guard Bundle(url: url) != nil else {
            alert("无法识别这个软件，请选择 .app 应用。")
            return
        }

        let copyURL = HiddenAppManager.copyURL(for: url)
        let entry = SelectedApp(originalPath: url.path, copyPath: copyURL.path)

        // 隐藏副本已在运行：直接显示窗口
        if let running = HiddenAppManager.runningCopy(of: entry) {
            showWindow(running)
            return
        }

        // App Store 应用无法重新签名
        let receipt = url.appendingPathComponent("Contents/_MASReceipt")
        if FileManager.default.fileExists(atPath: receipt.path) {
            alert("“\(url.deletingPathExtension().lastPathComponent)”是 App Store 应用，无法制作隐藏副本。")
            return
        }

        // 原版正在运行时会冲突，提示先退出
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            let originalRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { $0.bundleURL != copyURL }
            if originalRunning {
                let alert = NSAlert()
                alert.messageText = "“\(url.deletingPathExtension().lastPathComponent)”正在运行"
                alert.informativeText = "隐藏版与原版共用同一个软件身份，建议先退出原版，再重新在菜单里选择这个软件。"
                alert.addButton(withTitle: "知道了")
                alert.runModal()
                return
            }
        }

        do {
            let madeCopy = try HiddenAppManager.makeHiddenCopy(of: url)
            var apps = HiddenAppManager.storedApps()
            apps.removeAll { $0.originalPath == url.path }
            apps.append(SelectedApp(originalPath: url.path, copyPath: madeCopy.path))
            HiddenAppManager.save(apps)
            HiddenAppManager.launchHidden(entry) { _ in }
        } catch {
            alert("制作隐藏副本失败：\(error.localizedDescription)")
        }
    }

    @objc private func showWindowAction(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        showWindow(app)
    }

    @objc private func hideWindowAction(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        hideHiddenCopy(app)
    }

    @objc private func terminateAction(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        app.terminate()
    }

    @objc private func launchAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SelectedApp else { return }
        HiddenAppManager.launchHidden(entry) { _ in }
    }

    @objc private func removeAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SelectedApp else { return }
        HiddenAppManager.remove(entry)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// 一键快速隐藏：所有隐藏副本的窗口立即消失；再按一次全部恢复。菜单栏图标始终保持可见。
    @objc private func togglePanic() {
        guard panicActive || AXHelper.isTrusted else {
            checkAccessibilityPermission()
            return
        }
        panicActive.toggle()
        if panicActive {
            hideAllHiddenAppWindows()
        } else {
            showAllHiddenAppWindows()
        }
    }

    private func showWindow(_ app: NSRunningApplication) {
        showHiddenCopy(app, activate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        unmuteAllApps()
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "隐藏工具"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - 命令行测试模式（隐藏指定软件并报告状态）

func runCLIHiddenLaunch(path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        let copyURL = try HiddenAppManager.makeHiddenCopy(of: url)
        print("COPY=\(copyURL.path)")

        var launched: NSRunningApplication?
        var launchError: Error?
        var done = false
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: copyURL, configuration: config) { app, error in
            launched = app
            launchError = error
            done = true
        }
        while !done {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        print("LAUNCHED=\(launched != nil) ERR=\(String(describing: launchError))")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
        guard let app = launched else {
            print("NOT_RUNNING")
            exit(1)
        }
        print("POLICY=\(app.activationPolicy.rawValue)") // 0=regular，1=accessory
        print("WINDOWS=\(visibleWindowCount(of: Int(app.processIdentifier)))")
        print("PID=\(app.processIdentifier)")
    } catch {
        print("ERROR=\(error.localizedDescription)")
        exit(1)
    }
}

/// 一键快速隐藏的端到端测试：启动隐藏副本 → 触发隐藏 → 检查窗口数量。
func runCLIPanicTest(path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        let copyURL = try HiddenAppManager.makeHiddenCopy(of: url)
        let entry = SelectedApp(originalPath: url.path, copyPath: copyURL.path)
        var apps = HiddenAppManager.storedApps()
        apps.removeAll { $0.originalPath == url.path }
        apps.append(entry)
        HiddenAppManager.save(apps)

        var launched: NSRunningApplication?
        var done = false
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: copyURL, configuration: config) { app, _ in
            launched = app
            done = true
        }
        while !done {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        print("POLICY=\(launched?.activationPolicy.rawValue ?? -1)")
        print("COPY_PATH=\(entry.copyPath)")
        print("BUNDLE_URL=\(launched?.bundleURL?.path ?? "nil")")
        print("EXEC_URL=\(launched?.executableURL?.path ?? "nil")")
        print("AX_TRUSTED=\(AXHelper.isTrusted)")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
        print("WINDOWS_BEFORE=\(visibleWindowCount(of: launched.map { Int($0.processIdentifier) } ?? -1))")

        hideAllHiddenAppWindows()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        print("WINDOWS_AFTER=\(visibleWindowCount(of: launched.map { Int($0.processIdentifier) } ?? -1))")

        HiddenAppManager.remove(entry)
        launched?.terminate()
    } catch {
        print("ERROR=\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

func visibleWindowCount(of pid: Int) -> Int {
    guard pid > 0 else { return -1 }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var count = 0
    for window in windows {
        guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
        if (window[kCGWindowLayer as String] as? Int ?? -1) == 0 { count += 1 }
    }
    return count
}

// MARK: - 入口

var autoPanicTestPath: String?
if CommandLine.arguments.contains("--auto-panic-test"),
   let index = CommandLine.arguments.firstIndex(of: "--auto-panic-test"),
   CommandLine.arguments.count > index + 1 {
    autoPanicTestPath = CommandLine.arguments[index + 1]
}

if CommandLine.arguments.contains("--panic-test"),
   let index = CommandLine.arguments.firstIndex(of: "--panic-test"),
   CommandLine.arguments.count > index + 1 {
    runCLIPanicTest(path: CommandLine.arguments[index + 1])
}

if CommandLine.arguments.contains("--mute-test"),
   let index = CommandLine.arguments.firstIndex(of: "--mute-test"),
   CommandLine.arguments.count > index + 1,
   let pid = pid_t(CommandLine.arguments[index + 1]) {
    if #available(macOS 14.2, *) {
        print("SCREEN_PERMISSION=\(AudioMuteManager.screenRecordingGranted)")
        let ok = AudioMuteManager.shared.mute(pid: pid)
        print("MUTE=\(ok)")
        Thread.sleep(forTimeInterval: 2.0)
        AudioMuteManager.shared.unmute(pid: pid)
        print("UNMUTED")
    }
    exit(0)
}

// 单实例保护：已经有一个“隐藏工具”在运行时，新打开的实例直接退出。
let myPID = ProcessInfo.processInfo.processIdentifier
let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.caoyun.hiddentools")
    .filter { $0.processIdentifier != myPID && !$0.isTerminated }
if !otherInstances.isEmpty {
    exit(0)
}

if CommandLine.arguments.contains("--launch-hidden"),
   let index = CommandLine.arguments.firstIndex(of: "--launch-hidden"),
   CommandLine.arguments.count > index + 1 {
    runCLIHiddenLaunch(path: CommandLine.arguments[index + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
