import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import NagaStudio

nonisolated struct ActionCall: Equatable, Sendable {
    var action: EngineAction
    var phase: ActionPhase
}

nonisolated struct KeyEmission: Equatable, Sendable {
    var type: CGEventType
    var code: UInt16
    var flags: CGEventFlags
    var repeated: Bool

    init(_ event: CGEvent) {
        type = event.type
        code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        flags = event.flags
        repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }
}

nonisolated final class EventState: Sendable {
    let calls = Mutex<[ActionCall]>([])
    let device = Mutex(EventOrigin.naga)
    let clock = Mutex<UInt64>(1_000_000_000)
}

nonisolated final class EventHarness: Sendable {
    let state = EventState()
    let engine: EventEngine

    init(config: EngineConfig = EngineConfig()) {
        let state = state
        engine = EventEngine(
            origin: { _ in state.device.withLock { $0 } },
            isSystemProcess: { $0 == 0 },
            performAction: { action, phase in state.calls.withLock { $0.append(ActionCall(action: action, phase: phase)) } },
            now: { state.clock.withLock { $0 } }
        )
        engine.update(config)
    }

    var recorded: [ActionCall] { state.calls.withLock { $0 } }

    @discardableResult
    func send(_ type: CGEventType, code: UInt16 = 18, mouse: Int64 = 1,
              repeated: Bool = false, synthetic: Bool = false, horizontal: Double = 0) throws -> Bool {
        let event = try #require(CGEvent(source: nil))
        event.type = type
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        event.setIntegerValueField(.mouseEventButtonNumber, value: mouse)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: horizontal)
        if synthetic { event.setIntegerValueField(.eventSourceUserData, value: ActionPerformer.syntheticMarker) }
        return engine.handle(type, event) == nil
    }
}

struct CharacterizationTests {
    @MainActor @Test func assignmentConversion() {
        let cases: [(ButtonAction, EngineAction?)] = [
            (.original, nil), (.disabled, .swallow), (.click(.middle), .click(.middle)),
            (.shortcut(KeyCombo(keyCode: 18, modifiers: [])), .keys(keyCode: 18, modifiers: [])),
            (.shortcut(KeyCombo(keyCode: 18, modifiers: [.control, .shift])),
             .keys(keyCode: 18, modifiers: [.control, .shift])),
            (.preset(.copy), .keys(keyCode: 42, modifiers: .command)),
            (.preset(.spotlight), .keys(keyCode: 49, modifiers: .command)),
            (.preset(.missionControl), .dock("com.apple.expose.awake")),
            (.preset(.mute), .media(7)), (.text("hello"), .text("hello")),
            (.text(""), .swallow), (.app(path: "/Applications/Test.app"), .openApp("/Applications/Test.app")),
        ]
        for (assignment, expected) in cases {
            #expect(assignment.engineAction(using: ["c": 42]) == expected)
        }
    }

    @Test(arguments: [ModifierSet(), .command, [.control, .shift]])
    func fixedShortcutSequence(modifiers: ModifierSet) {
        let events = Mutex<[KeyEmission]>([])
        let performer = ActionPerformer(postEvent: { event in events.withLock { $0.append(KeyEmission(event)) } })
        let action = EngineAction.keys(keyCode: 18, modifiers: modifiers)
        for phase in [ActionPhase.down, .repeated, .up] { performer.perform(action, phase: phase) }
        let recorded = events.withLock { $0 }
        let keys = recorded.filter { $0.type != .flagsChanged }
        #expect(keys.map(\.type) == [.keyDown, .keyDown, .keyUp])
        #expect(keys.map(\.code) == [18, 18, 18])
        #expect(keys.map(\.repeated) == [false, true, false])
        #expect(keys.allSatisfy { $0.flags == modifiers.cgFlags })
        let changes = recorded.filter { $0.type == .flagsChanged }
        #expect(changes.count == modifiers.rawValue.nonzeroBitCount * 2)
        #expect(changes.last?.flags == (modifiers.isEmpty ? nil : []))
    }

    @Test func targetedKeyLifecycle() throws {
        let action = EngineAction.keys(keyCode: 0, modifiers: .command)
        let harness = EventHarness(config: EngineConfig(buttonsByInput: [.key(18): .side1], actions: [.side1: action]))
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.keyDown, repeated: true))
        #expect(try harness.send(.keyUp))
        #expect(harness.recorded == [.init(action: action, phase: .down),
                                     .init(action: action, phase: .repeated), .init(action: action, phase: .up)])
    }

    @Test func otherDeviceAndSyntheticPassThrough() throws {
        let harness = EventHarness(config: EngineConfig(buttonsByInput: [.key(18): .side1], actions: [.side1: .swallow]))
        harness.state.device.withLock { $0 = .otherDevice }
        for type in [CGEventType.keyDown, .keyUp] { #expect(try !harness.send(type)) }
        harness.state.device.withLock { $0 = .naga }
        for type in [CGEventType.keyDown, .keyUp] { #expect(try !harness.send(type, synthetic: true)) }
        #expect(harness.recorded.isEmpty)
    }

    @Test func unmappedInputAndFrontmostWindow() throws {
        let harness = EventHarness()
        #expect(try !harness.send(.keyDown))
        #expect(try !harness.send(.keyUp))
        harness.engine.update(EngineConfig(isAppFrontmost: true))
        #expect(try harness.send(.keyDown))
        #expect(try harness.send(.keyUp))
        #expect(harness.recorded == [.init(action: .swallow, phase: .down), .init(action: .swallow, phase: .up)])
    }

    @Test func unattributedMiddleClickRouting() throws {
        let harness = EventHarness(config: EngineConfig(
            isNagaConnected: true, buttonsByInput: [.mouse(2): .wheelClick], actions: [.wheelClick: .swallow]
        ))
        harness.state.device.withLock { $0 = .unattributed(pid: 123) }
        #expect(try !harness.send(.otherMouseDown, mouse: 2))
        harness.state.device.withLock { $0 = .unattributed(pid: 0) }
        #expect(try harness.send(.otherMouseDown, mouse: 2))
        #expect(try harness.send(.otherMouseUp, mouse: 2))
        #expect(harness.recorded.count == 2)
    }

    @Test(arguments: [false, true])
    func disabledAndDetection(detecting: Bool) throws {
        let harness = EventHarness(config: EngineConfig(
            isRemappingEnabled: false, isDetecting: detecting,
            buttonsByInput: [.key(18): .side1], actions: [.side1: .keys(keyCode: 0, modifiers: .command)]
        ))
        #expect(try harness.send(.keyDown) == detecting)
        #expect(try harness.send(.keyUp) == detecting)
        #expect(harness.recorded == (detecting ? [.init(action: .swallow, phase: .down), .init(action: .swallow, phase: .up)] : []))
    }

    @Test func mouseAndLockedLeftClick() throws {
        let harness = EventHarness(config: EngineConfig(
            buttonsByInput: [.mouse(0): .leftClick, .mouse(1): .rightClick],
            actions: [.leftClick: .swallow, .rightClick: .click(.middle)]
        ))
        #expect(try !harness.send(.leftMouseDown, mouse: 0))
        #expect(try !harness.send(.leftMouseUp, mouse: 0))
        #expect(try harness.send(.rightMouseDown))
        #expect(try harness.send(.rightMouseDragged))
        #expect(try harness.send(.rightMouseUp))
        #expect(harness.recorded == [.init(action: .click(.middle), phase: .down), .init(action: .click(.middle), phase: .up)])
    }

    @Test func tiltIsDebouncedPulse() throws {
        let harness = EventHarness(config: EngineConfig(
            isSystemNatural: false, buttonsByInput: [.tilt(.left): .tiltLeft], actions: [.tiltLeft: .click(.back)]
        ))
        #expect(try harness.send(.scrollWheel, horizontal: 1))
        #expect(try harness.send(.scrollWheel, horizontal: 1))
        #expect(harness.recorded == [.init(action: .click(.back), phase: .down), .init(action: .click(.back), phase: .up)])
        harness.state.clock.withLock { $0 += 400_000_000 }
        #expect(try harness.send(.scrollWheel, horizontal: 1))
        #expect(harness.recorded.count == 4)
    }

    @Test func legacySettingsAndPersistence() throws {
        let id = "C9CD5357-FBB1-49EF-9EFA-664DBE015538"
        let data = Data("""
        {"profiles":[{"id":"\(id)","name":"Existing","actions":{
          "side1":{"shortcut":{"_0":{"keyCode":18,"modifiers":0}}},
          "side12":{"preset":{"_0":"copy"}}}}],
          "activeProfileID":"\(id)","isRemappingEnabled":false,"scrollDirection":"natural",
          "learnedInputs":{"ringFinger":{"mouse":{"_0":7}}}}
        """.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        #expect(settings.profiles[0].actions[.side1] == .shortcut(KeyCombo(keyCode: 18, modifiers: [])))
        #expect(settings.profiles[0].actions[.side12] == .preset(.copy))
        #expect(settings.learnedInputs[.ringFinger] == .mouse(7))
        #expect(!settings.isRemappingEnabled)
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(restored.profiles == settings.profiles)
        #expect(restored.activeProfileID == settings.activeProfileID)
        #expect(restored.learnedInputs == settings.learnedInputs)
        #expect(restored.scrollDirection == .natural)
    }
}
