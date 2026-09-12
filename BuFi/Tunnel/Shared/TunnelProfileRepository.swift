import Foundation

enum TunnelProfileRepositoryError: LocalizedError, Sendable {
    case appGroupUnavailable
    case encoding

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: "The Bufi Tunnel app group is unavailable."
        case .encoding: "Tunnel profiles could not be encoded."
        }
    }
}

actor TunnelProfileRepository {
    static let shared = TunnelProfileRepository()

    private func defaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: TunnelConstants.appGroup) else {
            throw TunnelProfileRepositoryError.appGroupUnavailable
        }
        return defaults
    }

    func all() throws -> [TunnelProfile] {
        guard let data = try defaults().data(forKey: TunnelConstants.profileStoreKey) else {
            return []
        }
        return try JSONDecoder().decode([TunnelProfile].self, from: data)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func profile(id: UUID) throws -> TunnelProfile? {
        try all().first { $0.id == id }
    }

    func save(_ profile: TunnelProfile) throws {
        var profiles = try all().filter { $0.id != profile.id }
        profiles.append(profile)
        guard let data = try? JSONEncoder().encode(profiles) else {
            throw TunnelProfileRepositoryError.encoding
        }
        try defaults().set(data, forKey: TunnelConstants.profileStoreKey)
    }

    func delete(id: UUID) throws {
        let profiles = try all().filter { $0.id != id }
        guard let data = try? JSONEncoder().encode(profiles) else {
            throw TunnelProfileRepositoryError.encoding
        }
        try defaults().set(data, forKey: TunnelConstants.profileStoreKey)
    }

    func saveDiagnostics(_ diagnostics: TunnelDiagnostics) throws {
        guard let data = try? JSONEncoder().encode(diagnostics) else {
            throw TunnelProfileRepositoryError.encoding
        }
        try defaults().set(data, forKey: TunnelConstants.diagnosticsKey)
    }

    func diagnostics() throws -> TunnelDiagnostics? {
        guard let data = try defaults().data(forKey: TunnelConstants.diagnosticsKey) else {
            return nil
        }
        return try JSONDecoder().decode(TunnelDiagnostics.self, from: data)
    }
}

