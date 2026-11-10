import AppKit
import CoreGraphics
import os

/// An action resolved for the event tap thread: no layout lookups or UI state left.
nonisolated enum EngineAction: Sendable, Equatable {
    case swallow
    case keys(keyCode: UInt16, modifiers: ModifierSet, preservesPhysicalModifiers: Bool = false)
    case click(MouseClick)
    case dock(String)
    case media(Int32)
    case text(String)
    case openApp(String)
}

nonisolated enum ActionPhase: Sendable, Equatable {
    case down, up, repeated
}

/// Mutable output ownership belongs exclusively to the event-tap run loop.
nonisolated final class ActionPerformer: @unchecked Sendable {
    static let syntheticMarker: Int64 = 0x4E41_4741
    private let postEvent: @Sendable (CGEvent) -> Void
    private var shortcuts: [NagaInput: Shortcut] = [:]
    private var syntheticKeys: Set<UInt16> = []
    private var syntheticModifiers: ModifierSet = []
    private var physicalKeys: Set<UInt16> = []

    private struct Shortcut {
        var keyCode: UInt16
        var modifiers: ModifierSet
        var preservesPhysicalModifiers: Bool
    }

    init(postEvent: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.postEvent = postEvent
    }

    private static let modifierKeys: [(modifier: ModifierSet, keyCode: UInt16, flag: CGEventFlags)] = [
        (.control, 59, .maskControl),
        (.option, 58, .maskAlternate),
        (.shift, 56, .maskShift),
        (.command, 55, .maskCommand),
    ]

    func perform(_ action: EngineAction, phase: ActionPhase, input: NagaInput = .mouse(-1)) {
        switch action {
        case .swallow:
            return
        case let .keys(keyCode, modifiers, preservesPhysicalModifiers):
            postShortcut(Shortcut(keyCode: keyCode, modifiers: modifiers,
                                  preservesPhysicalModifiers: preservesPhysicalModifiers), phase: phase, input: input)
        case .click(let click):
            postClick(click, phase: phase)
        case .dock(let notification):
            guard phase == .down else { return }
            Task { @MainActor in Self.sendDockNotification(notification) }
        case .media(let key):
            guard phase == .down else { return }
            Task { @MainActor in Self.postMediaKey(key) }
        case .text(let text):
            guard phase == .down else { return }
            type(text)
        case .openApp(let path):
            guard phase == .down else { return }
            Task { @MainActor in Self.openApp(at: path) }
        }
    }

    private var physicalModifiers: ModifierSet { ModifierSet(physicalKeys: physicalKeys) }

    private func flags(for shortcut: Shortcut) -> CGEventFlags {
        let modifiers = shortcut.preservesPhysicalModifiers ? shortcut.modifiers.union(physicalModifiers) : shortcut.modifiers
        return modifiers.cgFlags.union(Self.implicitFlags(for: shortcut.keyCode))
    }

    private func postShortcut(_ shortcut: Shortcut, phase: ActionPhase, input: NagaInput) {
        switch phase {
        case .down:
            guard shortcuts[input] == nil else { return }
            shortcuts[input] = shortcut
            synchronizeModifiers()
            if !syntheticKeys.contains(shortcut.keyCode), !physicalKeys.contains(shortcut.keyCode) {
                syntheticKeys.insert(shortcut.keyCode)
                postKey(shortcut.keyCode, isDown: true, flags: flags(for: shortcut))
            }
        case .repeated:
            guard let held = shortcuts[input], !physicalKeys.contains(held.keyCode) else { return }
            postKey(held.keyCode, isDown: true, flags: flags(for: held), isRepeat: true)
        case .up:
            guard let held = shortcuts.removeValue(forKey: input) else { return }
            if !shortcuts.values.contains(where: { $0.keyCode == held.keyCode }),
               syntheticKeys.remove(held.keyCode) != nil, !physicalKeys.contains(held.keyCode) {
                postKey(held.keyCode, isDown: false, flags: flags(for: held))
            }
            synchronizeModifiers()
        }
    }

    func updatePhysicalKeys(_ keys: Set<UInt16>) {
        let previous = physicalModifiers
        physicalKeys = keys
        // A hardware release passes through unchanged, so reassert an explicit modifier still owned by an action.
        syntheticModifiers.subtract(previous.subtracting(physicalModifiers))
        synchronizeModifiers()
    }

    func physicalKeyChanged(_ code: UInt16, isDown: Bool) {
        let wasDown = physicalKeys.contains(code)
        if isDown { physicalKeys.insert(code) } else { physicalKeys.remove(code) }
        if !isDown, wasDown, let held = shortcuts.values.first(where: { $0.keyCode == code }) {
            syntheticKeys.insert(code)
            postKey(code, isDown: true, flags: flags(for: held))
        }
    }

    private func synchronizeModifiers() {
        let required = shortcuts.values.reduce(ModifierSet()) { $0.union($1.modifiers) }
        for key in Self.modifierKeys where required.contains(key.modifier)
            && !syntheticModifiers.contains(key.modifier) && !physicalModifiers.contains(key.modifier) {
            syntheticModifiers.insert(key.modifier)
            postKey(key.keyCode, isDown: true, flags: syntheticModifiers.union(physicalModifiers).cgFlags, isModifier: true)
        }
        for key in Self.modifierKeys.reversed() where syntheticModifiers.contains(key.modifier) && !required.contains(key.modifier) {
            syntheticModifiers.remove(key.modifier)
            if !physicalModifiers.contains(key.modifier) {
                postKey(key.keyCode, isDown: false, flags: syntheticModifiers.union(physicalModifiers).cgFlags, isModifier: true)
            }
        }
    }

    private func postKey(_ keyCode: UInt16, isDown: Bool, flags: CGEventFlags,
                         isModifier: Bool = false, isRepeat: Bool = false) {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
            Self.logger.error("Could not create a remapped keyboard event.")
            return
        }
        if isModifier { event.type = .flagsChanged }
        event.flags = flags
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        emit(event)
    }

    /// Arrow, navigation and function keys carry these flags when typed on a real keyboard.
    private static func implicitFlags(for keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case 123...126: [.maskSecondaryFn, .maskNumericPad]
        case 96...122: [.maskSecondaryFn]
        default: []
        }
    }

    private func postClick(_ click: MouseClick, phase: ActionPhase) {
        guard phase != .repeated else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        let isDown = phase == .down
        switch click {
        case .left:
            postMouse(isDown ? .leftMouseDown : .leftMouseUp, button: .left, number: 0, at: location)
        case .right:
            postMouse(isDown ? .rightMouseDown : .rightMouseUp, button: .right, number: 1, at: location)
        case .middle:
            postMouse(isDown ? .otherMouseDown : .otherMouseUp, button: .center, number: 2, at: location)
        case .back:
            postMouse(isDown ? .otherMouseDown : .otherMouseUp, button: .center, number: 3, at: location)
        case .forward:
            postMouse(isDown ? .otherMouseDown : .otherMouseUp, button: .center, number: 4, at: location)
        case .double:
            guard isDown else { return }
            for clickState: Int64 in [1, 2] {
                postMouse(.leftMouseDown, button: .left, number: 0, at: location, clickState: clickState)
                postMouse(.leftMouseUp, button: .left, number: 0, at: location, clickState: clickState)
            }
        }
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, number: Int64, at location: CGPoint, clickState: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        emit(event)
    }

    private func type(_ text: String) {
        let units = Array(text.utf16)
        // Apps drop unicode payloads longer than about 20 UTF-16 units per event.
        for start in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event.flags = []
                emit(event)
            }
        }
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private func emit(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        postEvent(event)
    }

    @MainActor private static func postMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let state = isDown ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                 data1: Int(key) << 16 | state << 8, data2: -1)?.cgEvent else { continue }
            post(event)
        }
    }

    private typealias DockNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    @MainActor private static func sendDockNotification(_ name: String) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            return
        }
        unsafeBitCast(symbol, to: DockNotification.self)(name as CFString, nil)
    }

    @MainActor private static func openApp(at path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { logger.error("Could not open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static let logger = Logger(subsystem: "com.marclou.naga-studio", category: "actions")
}
