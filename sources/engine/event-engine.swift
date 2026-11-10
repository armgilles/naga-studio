import CoreGraphics
import Foundation
import Synchronization
import os

nonisolated struct EngineConfig: Sendable {
    var profileID: UUID?
    var isRemappingEnabled = true
    var invertsScroll = false
    /// Detect is listening: every Naga press is captured for binding and does nothing else.
    var isDetecting = false
    /// Unmapped Naga keys would only type stray digits into the app's own window.
    var isAppFrontmost = false
    var isNagaConnected = false
    var isSystemNatural = true
    var buttonsByInput: [NagaInput: NagaButton] = [:]
    var actions: [NagaButton: EngineAction] = [:]

    func mappedAction(for button: NagaButton?) -> EngineAction? {
        guard isRemappingEnabled, let button else { return nil }
        return actions[button]
    }

    func requiresRelease(comparedTo previous: EngineConfig) -> Bool {
        profileID != previous.profileID || actions != previous.actions || buttonsByInput != previous.buttonsByInput
            || isRemappingEnabled != previous.isRemappingEnabled || isDetecting != previous.isDetecting
            || (previous.isNagaConnected && !isNagaConnected)
    }
}

nonisolated struct InputSignal: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case down, up, tap, scrollUp, scrollDown
    }

    var input: NagaInput?
    var button: NagaButton?
    var kind: Kind
    var didRunAction = false
}

/// The user-space driver: an event tap that sees every input before apps do and rewrites the Naga's.
nonisolated final class EventEngine: @unchecked Sendable {
    let signals: AsyncStream<InputSignal>

    private let continuation: AsyncStream<InputSignal>.Continuation
    private struct Configuration: Sendable {
        var value = EngineConfig()
        var revision: UInt64 = 0
    }
    private struct TapState: @unchecked Sendable {
        var port: CFMachPort?
        var loop: CFRunLoop?
        var isStopping = false
        var finished = DispatchSemaphore(value: 0)
    }

    private let config = Mutex(Configuration())
    private let origin: @Sendable (CGEvent) -> EventOrigin
    private let isSystemProcess: @Sendable (Int64) -> Bool
    private let performer: ActionPerformer
    private let performAction: @Sendable (EngineAction, ActionPhase, NagaInput) -> Void
    private let now: @Sendable () -> UInt64
    private let keyState: @Sendable (UInt16) -> Bool
    private let hasDeviceIdentification: Bool

    private let tapState = Mutex(TapState())

    // Touched only on the tap thread.
    private var activeActions: [NagaInput: EngineAction] = [:]
    private var suppressedInputs: Set<NagaInput> = []
    private var appliedConfig = EngineConfig()
    private var appliedRevision: UInt64 = 0
    private var physicalKeys: Set<UInt16> = []
    private var hasPhysicalState = false
    private var lastTiltTime: [TiltDirection: UInt64] = [:]
    private var lastScrollSignalTime: UInt64 = 0

    private static let tiltPressGap: UInt64 = 300_000_000
    private static let scrollSignalGap: UInt64 = 40_000_000

    init(
        origin: (@Sendable (CGEvent) -> EventOrigin)? = nil,
        isSystemProcess: (@Sendable (Int64) -> Bool)? = nil,
        performer: ActionPerformer = ActionPerformer(),
        performAction: (@Sendable (EngineAction, ActionPhase, NagaInput) -> Void)? = nil,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        keyState: @escaping @Sendable (UInt16) -> Bool = { CGEventSource.keyState(.hidSystemState, key: $0) }
    ) {
        let resolver = DeviceResolver()
        self.origin = origin ?? { resolver.origin(of: $0) }
        self.isSystemProcess = isSystemProcess ?? { resolver.isSystemProcess($0) }
        self.performer = performer
        self.performAction = performAction ?? { performer.perform($0, phase: $1, input: $2) }
        self.now = now
        self.keyState = keyState
        hasDeviceIdentification = origin != nil || resolver.isAvailable
        (signals, continuation) = AsyncStream.makeStream(of: InputSignal.self, bufferingPolicy: .bufferingNewest(256))
    }

    var canIdentifyDevices: Bool { hasDeviceIdentification }

    func update(_ newConfig: EngineConfig) {
        config.withLock {
            if newConfig.requiresRelease(comparedTo: $0.value) { $0.revision &+= 1 }
            $0.value = newConfig
        }
        if let loop = tapState.withLock({ $0.loop }) {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in synchronizeConfiguration() }
            CFRunLoopWakeUp(loop)
        }
    }

    /// Returns false when macOS refuses the tap, which means the permission is missing.
    func start() -> Bool {
        guard canIdentifyDevices else {
            Self.logger.error("Device identification is unavailable; remapping will not start.")
            return false
        }
        if let running = tapState.withLock({ $0.port == nil ? nil : !$0.isStopping }) { return running }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .scrollWheel,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .rightMouseDragged, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventEngine>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("macOS refused the event tap; check Accessibility and Input Monitoring permissions.")
            return false
        }

        tapState.withLock {
            $0.port = tap
            $0.isStopping = false
            $0.finished = DispatchSemaphore(value: 0)
        }
        let thread = Thread { [self] in runTapLoop() }
        thread.name = "Naga Studio event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func runTapLoop() {
        let state = tapState.withLock { $0 }
        guard let tap = state.port else { return }
        let loop = CFRunLoopGetCurrent()!
        tapState.withLock { $0.loop = loop }
        defer {
            CFMachPortInvalidate(tap)
            tapState.withLock { $0.port = nil; $0.loop = nil }
            state.finished.signal()
        }
        guard !tapState.withLock({ $0.isStopping }) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        refreshPhysicalState()
        synchronizeConfiguration()
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
        refreshPhysicalState()
        cancelActiveActions()
        hasPhysicalState = false
    }

    /// Called off the input thread; shutdown waits for its queued releases before the app exits.
    func stop() {
        let state = tapState.withLock {
            $0.isStopping = true
            return $0
        }
        guard state.port != nil else {
            refreshPhysicalState()
            cancelActiveActions()
            hasPhysicalState = false
            return
        }
        if let loop = state.loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }
        if state.finished.wait(timeout: .now() + 2) == .timedOut {
            Self.logger.error("Timed out waiting for the event tap to release active actions.")
        }
    }

    func synchronizeConfiguration() {
        let pending = config.withLock { $0 }
        if !hasPhysicalState || appliedRevision != pending.revision {
            refreshPhysicalState()
        }
        if appliedRevision != pending.revision {
            cancelActiveActions()
            appliedRevision = pending.revision
        }
        appliedConfig = pending.value
    }

    private func refreshPhysicalState() {
        physicalKeys = Set((UInt16(0)..<128).filter(keyState))
        performer.updatePhysicalKeys(physicalKeys)
        hasPhysicalState = true
    }

    private func cancelActiveActions() {
        for (input, action) in activeActions {
            performAction(action, .up, input)
            emit(input, appliedConfig.buttonsByInput[input], .up)
            suppressedInputs.insert(input)
        }
        activeActions.removeAll()
        lastTiltTime.removeAll()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            refreshPhysicalState()
            cancelActiveActions()
            Self.logger.warning("Event tap was interrupted; active actions were released.")
            if let tap = tapState.withLock({ $0.isStopping ? nil : $0.port }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return passthrough
        }
        guard event.getIntegerValueField(.eventSourceUserData) != ActionPerformer.syntheticMarker else { return passthrough }

        synchronizeConfiguration()
        if type == .flagsChanged {
            if isSystemProcess(event.getIntegerValueField(.eventSourceUnixProcessID)) {
                for code in ModifierSet.physicalKeyCodes {
                    if keyState(code) { physicalKeys.insert(code) } else { physicalKeys.remove(code) }
                }
                performer.updatePhysicalKeys(physicalKeys)
            }
            return passthrough
        }
        let config = appliedConfig
        let eventOrigin = origin(event)
        guard isFromNaga(type, event, config, origin: eventOrigin) else {
            if (type == .keyDown || type == .keyUp),
               isSystemProcess(event.getIntegerValueField(.eventSourceUnixProcessID)) {
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .keyDown { physicalKeys.insert(code) } else { physicalKeys.remove(code) }
                performer.physicalKeyChanged(code, isDown: type == .keyDown)
            }
            return passthrough
        }
        let shouldSwallow = switch type {
        case .keyDown, .keyUp: handleKey(type, event, config)
        case .scrollWheel: handleScroll(event, config)
        case .rightMouseDragged, .otherMouseDragged:
            activeActions[.mouse(Int(event.getIntegerValueField(.mouseEventButtonNumber)))] != nil
        default: handleMouseButton(type, event, config)
        }
        return shouldSwallow ? nil : passthrough
    }

    private func isFromNaga(_ type: CGEventType, _ event: CGEvent, _ config: EngineConfig, origin: EventOrigin) -> Bool {
        switch origin {
        case .naga:
            true
        case .otherDevice:
            false
        case .unattributed(let pid):
            // Middle clicks come without their device; the built-in trackpad never sends one, so a
            // hardware middle click while the Naga is connected is the Naga's wheel.
            canIdentifyDevices && config.isNagaConnected
                && event.getIntegerValueField(.mouseEventButtonNumber) == 2
                && [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(type)
                && isSystemProcess(pid)
        }
    }

    private func handleKey(_ type: CGEventType, _ event: CGEvent, _ config: EngineConfig) -> Bool {
        let input = NagaInput.key(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        let button = config.buttonsByInput[input]

        if suppressedInputs.contains(input) {
            if type == .keyUp {
                suppressedInputs.remove(input)
                return true
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            suppressedInputs.remove(input)
        }
        guard type == .keyDown else {
            emit(input, button, .up)
            guard let action = activeActions.removeValue(forKey: input) else { return false }
            performAction(action, .up, input)
            return true
        }

        if let action = activeActions[input] {
            performAction(action, .repeated, input)
            return true
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return false }

        let mapped = config.isDetecting ? nil : config.mappedAction(for: button)
        emit(input, button, .down, didRunAction: mapped != nil)
        let action = config.isDetecting || config.isAppFrontmost ? mapped ?? .swallow : mapped
        guard let action else { return false }
        activeActions[input] = action
        performAction(action, .down, input)
        return true
    }

    private func handleMouseButton(_ type: CGEventType, _ event: CGEvent, _ config: EngineConfig) -> Bool {
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let input = NagaInput.mouse(number)
        let button = config.buttonsByInput[input]
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown

        if suppressedInputs.remove(input) != nil, !isDown { return true }
        guard isDown else {
            emit(input, button, .up)
            guard number != 0, let action = activeActions.removeValue(forKey: input) else { return false }
            performAction(action, .up, input)
            return true
        }

        if activeActions[input] != nil { return true }
        let isLeftClick = number == 0
        let mapped = isLeftClick || config.isDetecting ? nil : config.mappedAction(for: button)
        emit(input, button, .down, didRunAction: mapped != nil)
        let action: EngineAction? = !isLeftClick && config.isDetecting ? .swallow : mapped
        guard let action else { return false }
        activeActions[input] = action
        performAction(action, .down, input)
        return true
    }

    private func handleScroll(_ event: CGEvent, _ config: EngineConfig) -> Bool {
        let vertical = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let horizontal = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        // Natural scrolling flips deltas before the tap sees them; undo that to get the physical direction.
        let physicalSign: Double = config.isSystemNatural ? -1 : 1
        let now = now()

        if vertical == 0, horizontal != 0 {
            let direction: TiltDirection = horizontal * physicalSign > 0 ? .left : .right
            let input = NagaInput.tilt(direction)
            let button = config.buttonsByInput[input]
            let isNewPress = now &- (lastTiltTime[direction] ?? 0) > Self.tiltPressGap
            lastTiltTime[direction] = now
            let mapped = config.isDetecting ? nil : config.mappedAction(for: button)
            if isNewPress { emit(input, button, .tap, didRunAction: mapped != nil) }
            if config.isDetecting { return true }
            if let mapped {
                if isNewPress {
                    performAction(mapped, .down, input)
                    performAction(mapped, .up, input)
                }
                return true
            }
        } else if vertical != 0, now &- lastScrollSignalTime > Self.scrollSignalGap {
            lastScrollSignalTime = now
            emit(nil, nil, vertical * physicalSign > 0 ? .scrollUp : .scrollDown)
        }

        if config.invertsScroll { Self.invert(event) }
        return false
    }

    private static func invert(_ event: CGEvent) {
        let delta1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let delta2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        // Order matters: setting the line delta recomputes the others.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed2)
    }

    private func emit(_ input: NagaInput?, _ button: NagaButton?, _ kind: InputSignal.Kind, didRunAction: Bool = false) {
        continuation.yield(InputSignal(input: input, button: button, kind: kind, didRunAction: didRunAction))
    }

    private static let logger = Logger(subsystem: "com.marclou.naga-studio", category: "events")
}
