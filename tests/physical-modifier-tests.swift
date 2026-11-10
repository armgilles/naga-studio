import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import NagaStudio

nonisolated final class KeyboardTestState: Sendable {
    let physicalKeys: Mutex<Set<UInt16>>
    let events = Mutex<[KeyEmission]>([])
    let origin = Mutex(EventOrigin.naga)

    init(heldKeys: Set<UInt16>) { physicalKeys = Mutex(heldKeys) }
}

nonisolated final class KeyboardHarness: Sendable {
    let state: KeyboardTestState
    let engine: EventEngine

    init(config: EngineConfig = KeyboardHarness.configuration(), heldKeys: Set<UInt16> = []) {
        let state = KeyboardTestState(heldKeys: heldKeys)
        self.state = state
        let performer = ActionPerformer(postEvent: { event in state.events.withLock { $0.append(KeyEmission(event)) } })
        engine = EventEngine(
            origin: { _ in state.origin.withLock { $0 } },
            isSystemProcess: { $0 == 0 },
            performer: performer,
            now: { 1_000_000_000 },
            keyState: { code in state.physicalKeys.withLock { $0.contains(code) } }
        )
        engine.update(config)
        engine.synchronizeConfiguration()
    }

    static func configuration(modifiers: ModifierSet = [], dynamic: Bool = true) -> EngineConfig {
        EngineConfig(
            isNagaConnected: true, isSystemNatural: false,
            buttonsByInput: [.key(18): .side1, .mouse(1): .rightClick],
            actions: [
                .side1: .keys(keyCode: 0, modifiers: modifiers, preservesPhysicalModifiers: dynamic),
                .rightClick: .keys(keyCode: 1, modifiers: modifiers, preservesPhysicalModifiers: dynamic),
            ]
        )
    }

    var events: [KeyEmission] { state.events.withLock { $0 } }
    var keys: [KeyEmission] { events.filter { $0.type == .keyDown || $0.type == .keyUp } }
    var modifierEvents: [KeyEmission] { events.filter { $0.type == .flagsChanged } }

    @discardableResult
    func send(_ type: CGEventType, code: UInt16 = 18, mouse: Int64 = 1, repeated: Bool = false,
              flags: CGEventFlags = [], synthetic: Bool = false, horizontal: Double = 0, pid: Int64 = 0) throws -> Bool {
        let event = try #require(CGEvent(source: nil))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        event.setIntegerValueField(.mouseEventButtonNumber, value: mouse)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: horizontal)
        if synthetic { event.setIntegerValueField(.eventSourceUserData, value: ActionPerformer.syntheticMarker) }
        let before = KeyEmission(event)
        let swallowed = engine.handle(type, event) == nil
        #expect(KeyEmission(event) == before, "Input events, especially physical keyboard events, must not be rewritten.")
        return swallowed
    }

    func modifiers(_ heldKeys: Set<UInt16>, code: UInt16 = 56) throws {
        state.physicalKeys.withLock { $0 = heldKeys }
        #expect(try !send(.flagsChanged, code: code, flags: ModifierSet(physicalKeys: heldKeys).cgFlags))
    }

    func physicalKey(_ code: UInt16, down: Bool, repeated: Bool = false) throws {
        state.physicalKeys.withLock {
            if down { $0.insert(code) } else { $0.remove(code) }
        }
        state.origin.withLock { $0 = .otherDevice }
        defer { state.origin.withLock { $0 = .naga } }
        #expect(try !send(down ? .keyDown : .keyUp, code: code, repeated: repeated, flags: .maskShift))
    }
}

nonisolated struct ButtonInputCase: Sendable {
    var button: NagaButton
    var input: NagaInput

    static let all: [Self] = NagaButton.allCases.enumerated().flatMap { index, button -> [Self] in
        guard !button.isLocked else { return [] }
        let inputs = button.defaultInputs.isEmpty ? [NagaInput.mouse(index + 3)] : button.defaultInputs
        return inputs.map { Self(button: button, input: $0) }
    }
}

struct PhysicalModifierTests {
    @Test(arguments: (0..<16).map { ModifierSet(rawValue: $0) }, [false, true])
    func physicalCombinationsAndFixedCompatibility(modifiers: ModifierSet, dynamic: Bool) throws {
        let held = Set(zip([ModifierSet.control, .option, .shift, .command], [UInt16(59), 58, 56, 55])
            .filter { modifiers.contains($0.0) }.map(\.1))
        let harness = KeyboardHarness(config: KeyboardHarness.configuration(dynamic: dynamic), heldKeys: held)
        #expect(try harness.send(.keyDown, flags: []))
        #expect(try harness.send(.keyDown, repeated: true, flags: []))
        #expect(try harness.send(.keyUp, flags: []))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyDown, .keyUp])
        #expect(harness.keys.map(\.repeated) == [false, true, false])
        #expect(harness.keys.allSatisfy { $0.code == 0 && $0.flags == (dynamic ? modifiers.cgFlags : []) })
        #expect(harness.modifierEvents.isEmpty, "Physical modifiers are not synthesized or released.")
        #expect(harness.events.allSatisfy { $0.synthetic })
    }

    @Test func unionOfRecordedAndPhysicalModifiers() throws {
        let harness = KeyboardHarness(config: KeyboardHarness.configuration(modifiers: [.control, .command]), heldKeys: [56, 55])
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.flags) == [ModifierSet([.control, .command, .shift]).cgFlags,
                                           ModifierSet([.control, .command, .shift]).cgFlags])
        #expect(harness.modifierEvents.map(\.code) == [59, 59])
        #expect(harness.modifierEvents.last?.flags == ModifierSet([.command, .shift]).cgFlags)
    }

    @Test func physicalModifiersChangeWhileMouseIsHeld() throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        try harness.modifiers([59, 56])
        #expect(harness.keys.count == 1, "Modifier changes must not retype or release the held key.")
        #expect(try harness.send(.keyDown, repeated: true))
        try harness.modifiers([56], code: 59)
        #expect(try harness.send(.keyDown, repeated: true))
        try harness.modifiers([], code: 56)
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.flags) == [[], ModifierSet([.control, .shift]).cgFlags, .maskShift, []])
        #expect(harness.modifierEvents.isEmpty)
    }

    @Test(arguments: [[UInt16(59), 62], [58, 61], [56, 60], [55, 54]], [false, true])
    func eitherModifierSideCanRemainHeld(pair: [UInt16], releaseRightFirst: Bool) throws {
        let harness = KeyboardHarness(heldKeys: [pair[0]])
        #expect(try harness.send(.keyDown))
        try harness.modifiers(Set(pair), code: pair[1])
        let remaining = releaseRightFirst ? pair[0] : pair[1]
        try harness.modifiers([remaining], code: releaseRightFirst ? pair[1] : pair[0])
        #expect(try harness.send(.keyDown, repeated: true))
        #expect(harness.keys.last?.flags == harness.keys.first?.flags)
        try harness.modifiers([], code: remaining)
        #expect(try harness.send(.keyDown, repeated: true))
        #expect(harness.keys.last?.flags == [])
        #expect(try harness.send(.keyUp))
    }

    @Test func sharedModifiersAndKeysAreReleasedOnlyByTheLastOwner() throws {
        var config = KeyboardHarness.configuration(modifiers: .control)
        config.actions[.rightClick] = .keys(keyCode: 0, modifiers: [.control, .shift], preservesPhysicalModifiers: true)
        let harness = KeyboardHarness(config: config)
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.rightMouseDown))
        #expect(try harness.send(.rightMouseDown))
        #expect(harness.keys.map(\.type) == [.keyDown])
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.type) == [.keyDown])
        #expect(harness.modifierEvents.map(\.code) == [59, 56])
        #expect(try harness.send(.rightMouseUp))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
        #expect(harness.modifierEvents.map(\.code) == [59, 56, 56, 59])
        #expect(harness.modifierEvents.last?.flags == [])
    }

    @Test func simultaneousDifferentKeysFollowLivePhysicalModifiers() throws {
        let harness = KeyboardHarness(config: KeyboardHarness.configuration(modifiers: .command))
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.rightMouseDown))
        try harness.modifiers([58])
        #expect(try harness.send(.keyDown, repeated: true))
        #expect(harness.keys.last?.flags == ModifierSet([.command, .option]).cgFlags)
        #expect(try harness.send(.keyUp))
        #expect(harness.modifierEvents.count == 1, "Command is still required by the other button.")
        #expect(try harness.send(.rightMouseUp))
        #expect(harness.keys.map(\.code) == [0, 1, 0, 0, 1])
        #expect(harness.modifierEvents.count == 2)
        #expect(harness.modifierEvents.last?.flags == .maskAlternate)
    }

    @Test func releasingAnActionNeverReleasesAPhysicallyHeldModifier() throws {
        let harness = KeyboardHarness(config: KeyboardHarness.configuration(modifiers: .control))
        #expect(try harness.send(.keyDown))
        try harness.modifiers([62], code: 62)
        #expect(try harness.send(.keyUp))
        #expect(harness.modifierEvents.count == 1, "No synthetic Control-up while right Control is physically held.")
        try harness.modifiers([], code: 62)
        #expect(harness.modifierEvents.count == 1)
    }

    @Test func explicitModifierIsReassertedAfterItsPhysicalRelease() throws {
        let harness = KeyboardHarness(config: KeyboardHarness.configuration(modifiers: .control), heldKeys: [59])
        #expect(try harness.send(.keyDown))
        #expect(harness.modifierEvents.isEmpty)
        try harness.modifiers([], code: 59)
        #expect(harness.modifierEvents.map(\.flags) == [.maskControl])
        #expect(try harness.send(.keyUp))
        #expect(harness.modifierEvents.map(\.flags) == [.maskControl, []])
    }

    @Test func syntheticAndAppPostedModifierEventsAreNotPhysical() throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        #expect(try !harness.send(.flagsChanged, code: 55, flags: .maskCommand, synthetic: true))
        #expect(try !harness.send(.flagsChanged, code: 58, flags: .maskAlternate, pid: 123))
        #expect(try harness.send(.keyDown, repeated: true))
        #expect(harness.keys.last?.flags == [])
        #expect(try !harness.send(.keyUp, synthetic: true))
        #expect(harness.keys.count == 2)
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyDown, .keyUp])
    }

    @Test func keyboardUsingTheSameSourceCodeIsNeverSwallowed() throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        try harness.physicalKey(18, down: true)
        try harness.physicalKey(18, down: true, repeated: true)
        try harness.physicalKey(18, down: false)
        #expect(harness.keys.map(\.type) == [.keyDown])
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
    }

    @Test func unattributedKeyboardEventsDoNotUseGlobalKeyCodeFallback() throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        harness.state.origin.withLock { $0 = .unattributed(pid: 0) }
        #expect(try !harness.send(.keyDown, repeated: true))
        #expect(try !harness.send(.keyUp))
        #expect(harness.keys.count == 1)
        harness.state.origin.withLock { $0 = .naga }
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.count == 2)
    }

    @Test func unknownKeyboardReleaseMustNotRetypeAnActiveOutputKey() throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        harness.state.origin.withLock { $0 = .unattributed(pid: 0) }
        #expect(try !harness.send(.keyUp, code: 0))
        #expect(harness.keys.map(\.type) == [.keyDown])
    }

    @Test func mouseHardwareKeyStateIsNotMistakenForKeyboardOwnershipDuringCleanup() throws {
        var config = KeyboardHarness.configuration()
        config.actions[.side1] = .keys(keyCode: 18, modifiers: [], preservesPhysicalModifiers: true)
        let harness = KeyboardHarness(config: config)
        // The public HID table includes the Naga's original hardware key, not just keyboard keys.
        harness.state.physicalKeys.withLock { _ = $0.insert(18) }
        #expect(try harness.send(.keyDown))
        config.isRemappingEnabled = false
        harness.engine.update(config)
        harness.engine.synchronizeConfiguration()
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
    }

    @Test func mouseButtonHeldAtActivationDoesNotLeavePhantomKeyboardOwnership() throws {
        var config = KeyboardHarness.configuration()
        config.actions[.side1] = .keys(keyCode: 18, modifiers: [], preservesPhysicalModifiers: true)
        let harness = KeyboardHarness(config: config, heldKeys: [18])
        harness.state.physicalKeys.withLock { _ = $0.remove(18) }
        #expect(try !harness.send(.keyUp))
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
    }

    @Test(arguments: [false, true])
    func physicalKeySharingTheOutputCodeIsNotReleasedByMouse(releaseKeyboardFirst: Bool) throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        try harness.physicalKey(0, down: true)
        if releaseKeyboardFirst {
            try harness.physicalKey(0, down: false)
            #expect(harness.keys.map(\.type) == [.keyDown, .keyDown], "Reassert the mouse-owned key after the unchanged hardware key-up.")
            #expect(try harness.send(.keyUp))
            #expect(harness.keys.last?.type == .keyUp)
        } else {
            #expect(try harness.send(.keyUp))
            #expect(harness.keys.map(\.type) == [.keyDown], "Do not synthesize a key-up while the keyboard still owns the key.")
            try harness.physicalKey(0, down: false)
            #expect(harness.keys.count == 1)
        }
    }

    @Test func outputKeyAlreadyHeldAtActivationIsNotDuplicated() throws {
        let harness = KeyboardHarness(heldKeys: [0])
        #expect(try harness.send(.keyDown))
        #expect(harness.keys.isEmpty)
        try harness.physicalKey(0, down: false)
        #expect(harness.keys.map(\.type) == [.keyDown])
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
    }

    @Test(arguments: ButtonInputCase.all)
    func everyRemappableInputCategory(incoming: ButtonInputCase) throws {
        let action = EngineAction.keys(keyCode: 18, modifiers: [], preservesPhysicalModifiers: true)
        let config = EngineConfig(
            isNagaConnected: true, isSystemNatural: false,
            buttonsByInput: [incoming.input: incoming.button], actions: [incoming.button: action]
        )
        let harness = KeyboardHarness(config: config, heldKeys: [55, 56])
        switch incoming.input {
        case .key(let code):
            #expect(try harness.send(.keyDown, code: code))
            #expect(try harness.send(.keyUp, code: code))
        case .mouse(let number):
            #expect(try harness.send(number == 1 ? .rightMouseDown : .otherMouseDown, mouse: Int64(number)))
            #expect(try harness.send(number == 1 ? .rightMouseUp : .otherMouseUp, mouse: Int64(number)))
        case .tilt(let direction):
            #expect(try harness.send(.scrollWheel, horizontal: direction == .left ? 1 : -1))
            #expect(try harness.send(.scrollWheel, horizontal: direction == .left ? 1 : -1))
        }
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
        #expect(harness.keys.allSatisfy { $0.flags == ModifierSet([.command, .shift]).cgFlags })
        #expect(harness.modifierEvents.isEmpty)
    }

    @Test(arguments: ["disable", "profile", "disconnect", "detect", "assignment"])
    func configurationChangesReleaseActionsAndSuppressTheirFollowUps(change: String) throws {
        var config = KeyboardHarness.configuration(modifiers: .command)
        let harness = KeyboardHarness(config: config, heldKeys: [56])
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.rightMouseDown))
        switch change {
        case "disable": config.isRemappingEnabled = false
        case "profile": config.profileID = UUID()
        case "disconnect": config.isNagaConnected = false
        case "detect": config.isDetecting = true
        default: config.actions = [:]
        }
        harness.engine.update(config)
        harness.engine.synchronizeConfiguration()
        #expect(harness.keys.filter { $0.type == .keyUp }.count == 2)
        #expect(harness.modifierEvents.map(\.flags) == [ModifierSet([.command, .shift]).cgFlags, .maskShift])
        let count = harness.events.count
        #expect(try harness.send(.keyDown, repeated: true))
        try harness.physicalKey(18, down: false)
        #expect(try harness.send(.keyUp))
        #expect(try harness.send(.rightMouseDragged))
        #expect(try harness.send(.rightMouseUp))
        #expect(harness.events.count == count)
    }

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func interruptionsReleaseActionsAndAllowAFreshPress(type: CGEventType) throws {
        let harness = KeyboardHarness()
        #expect(try harness.send(.keyDown))
        #expect(try !harness.send(type))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp])
        #expect(try harness.send(.keyDown, repeated: true))
        #expect(try harness.send(.keyUp))
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.keyUp))
        #expect(harness.keys.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
    }

    @Test func shutdownReleasesAllOwnedKeysButNotPhysicalModifiers() throws {
        let harness = KeyboardHarness(config: KeyboardHarness.configuration(modifiers: .control), heldKeys: [59])
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.rightMouseDown))
        harness.engine.stop()
        #expect(harness.keys.filter { $0.type == .keyUp }.count == 2)
        #expect(harness.modifierEvents.isEmpty)
    }

    @Test func leftClickStaysLockedAndOtherMiceStayUntouched() throws {
        let harness = KeyboardHarness(config: EngineConfig(
            isNagaConnected: true, buttonsByInput: [.mouse(0): .leftClick, .mouse(3): .ringFinger],
            actions: [.leftClick: .keys(keyCode: 0, modifiers: [], preservesPhysicalModifiers: true), .ringFinger: .swallow]
        ))
        #expect(try !harness.send(.leftMouseDown, mouse: 0))
        #expect(try !harness.send(.leftMouseUp, mouse: 0))
        harness.state.origin.withLock { $0 = .otherDevice }
        #expect(try !harness.send(.otherMouseDown, mouse: 3))
        harness.state.origin.withLock { $0 = .unattributed(pid: 0) }
        #expect(try !harness.send(.otherMouseDown, mouse: 3), "Only the existing middle-click heuristic may accept an unattributed mouse event.")
        #expect(harness.events.isEmpty)
    }

    @Test func missingDeviceIdentificationPreventsInterception() throws {
        let events = Mutex<[KeyEmission]>([])
        let engine = EventEngine(
            origin: { _ in .naga },
            performer: ActionPerformer(postEvent: { event in events.withLock { $0.append(KeyEmission(event)) } }),
            keyState: { _ in false },
            deviceIdentificationAvailable: false
        )
        engine.update(KeyboardHarness.configuration())
        #expect(!engine.canIdentifyDevices)
        #expect(!engine.start(), "This path must fail before attempting to create an event tap.")
        let event = try #require(CGEvent(source: nil))
        event.type = .keyDown
        event.setIntegerValueField(.keyboardEventKeycode, value: 18)
        #expect(engine.handle(.keyDown, event)?.takeUnretainedValue() === event)
        #expect(events.withLock { $0.isEmpty })
    }

    @MainActor @Test func optionPersistenceConversionAndNonKeyboardActions() throws {
        let profile = Profile(name: "Dynamic", actions: [.side12: .shortcut(KeyCombo(keyCode: 18, modifiers: .control))],
                              physicalModifierButtons: [.side12])
        var settings = Settings()
        settings.profiles = [profile]
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(restored.profiles == [profile])
        let suiteName = "com.marclou.naga-studio.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.save(to: defaults)
        #expect(Settings.load(from: defaults).profiles == [profile])
        #expect(restored.profiles[0].actions[.side12]?.engineAction(using: [:], preservesPhysicalModifiers: true)
                == .keys(keyCode: 18, modifiers: .control, preservesPhysicalModifiers: true))
        #expect(ButtonAction.preset(.copy).engineAction(using: ["c": 8], preservesPhysicalModifiers: true)
                == .keys(keyCode: 8, modifiers: .command, preservesPhysicalModifiers: true))
        for action in [ButtonAction.original, .disabled, .click(.right), .text("hello"), .app(path: "/Test.app"), .preset(.mute)] {
            #expect(!action.isKeyboardAction)
            #expect(action.engineAction(using: [:], preservesPhysicalModifiers: true) == action.engineAction(using: [:]))
        }
    }

    @MainActor @Test(arguments: NagaButton.allCases)
    func perAssignmentOptionFollowsProfileEditing(button: NagaButton) {
        let model = AppModel(isPreview: true)
        if button.defaultInputs.isEmpty { model.settings.learnedInputs[button] = .mouse(9) }
        model.assign(.shortcut(KeyCombo(keyCode: 18, modifiers: [])), to: button)
        model.setPreservesPhysicalModifiers(true, for: button)
        #expect(model.preservesPhysicalModifiers(for: button) == !button.isLocked)
        if button.isLocked {
            #expect(model.action(for: button) == .original)
            return
        }
        let sourceID = model.activeProfileID
        model.duplicateActiveProfile()
        #expect(model.preservesPhysicalModifiers(for: button))
        model.assign(.text("hello"), to: button)
        #expect(!model.preservesPhysicalModifiers(for: button))
        model.setPreservesPhysicalModifiers(true, for: button)
        #expect(!model.preservesPhysicalModifiers(for: button))
        model.activateProfile(sourceID)
        #expect(model.preservesPhysicalModifiers(for: button))
        model.resetActiveProfile()
        #expect(!model.preservesPhysicalModifiers(for: button))
    }
}
