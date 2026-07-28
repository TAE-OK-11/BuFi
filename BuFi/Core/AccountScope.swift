import CryptoKit
import Foundation

enum AccountScope {
    static func identifier(for credentials: ServerCredentials) -> String {
        let rawServer = credentials.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalServer: String

        if var components = URLComponents(string: rawServer) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            components.path = components.path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            canonicalServer = components.string ?? rawServer
        } else {
            canonicalServer = rawServer.lowercased()
        }

        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let material = canonicalServer + "\u{0}" + username
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
