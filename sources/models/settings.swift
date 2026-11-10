import Foundation
import os

nonisolated enum ScrollDirection: String, Codable, CaseIterable, Sendable {
    case standard, natural

    var title: String { self == .standard ? "Standard" : "Natural" }
}

nonisolated struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var actions: [NagaButton: ButtonAction] = [:]
    var physicalModifierButtons: Set<NagaButton> = []

    init(id: UUID = UUID(), name: String, actions: [NagaButton: ButtonAction] = [:],
         physicalModifierButtons: Set<NagaButton> = []) {
        self.id = id
        self.name = name
        self.actions = actions
        self.physicalModifierButtons = physicalModifierButtons
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        actions = try container.decode([NagaButton: ButtonAction].self, forKey: .actions)
        physicalModifierButtons = try container.decodeIfPresent(Set<NagaButton>.self, forKey: .physicalModifierButtons) ?? []
    }
}

nonisolated struct Settings: Codable, Sendable {
    var profiles = [Profile(name: "Default")]
    var activeProfileID: UUID?
    var isRemappingEnabled = true
    var scrollDirection = ScrollDirection.standard
    var learnedInputs: [NagaButton: NagaInput] = [:]

    private static let storageKey = "settings.v1"

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? profiles
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        isRemappingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isRemappingEnabled) ?? isRemappingEnabled
        scrollDirection = try container.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? scrollDirection
        learnedInputs = try container.decodeIfPresent([NagaButton: NagaInput].self, forKey: .learnedInputs) ?? [:]
        if profiles.isEmpty { profiles = [Profile(name: "Default")] }
    }

    static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: storageKey) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            logger.error("Could not decode saved settings: \(error.localizedDescription, privacy: .public)")
            return Settings()
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Could not encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "com.marclou.naga-studio", category: "settings")
}
