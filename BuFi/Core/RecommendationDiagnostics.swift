import Foundation

struct RecommendationDiagEvent: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var at: Date
    var kind: Kind
    var level: Level
    var title: String
    var detail: String

    enum Kind: String, Codable, Sendable {
        case llm
        case coreml
        case radio
    }

    enum Level: String, Codable, Sendable {
        case error
        case delay
        case info
    }

    var kindTitle: String {
        switch kind {
        case .llm: String(localized: "LLM")
        case .coreml: String(localized: "CoreML")
        case .radio: String(localized: "라디오")
        }
    }

    var levelTitle: String {
        switch level {
        case .error: String(localized: "오류")
        case .delay: String(localized: "지연")
        case .info: String(localized: "기록")
        }
    }
}

enum RecommendationDiagnostics {
    static let didChange = Notification.Name("BuFiRecommendationDiagnosticsDidChange")
    static let store = Store()

    static func record(
        kind: RecommendationDiagEvent.Kind,
        level: RecommendationDiagEvent.Level,
        title: String,
        detail: String = ""
    ) {
        store.record(
            RecommendationDiagEvent(
                id: UUID(),
                at: Date(),
                kind: kind,
                level: level,
                title: title,
                detail: detail
            )
        )
    }

    static func events() -> [RecommendationDiagEvent] {
        store.snapshot()
    }

    static func clear() {
        store.clear()
    }

    static func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return store.snapshot().map { event in
            let when = formatter.string(from: event.at)
            return "\(when) [\(event.kind.rawValue)/\(event.level.rawValue)] \(event.title) — \(event.detail)"
        }.joined(separator: "\n")
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RecommendationDiagEvent] = []
        private var lastSignature = ""
        private var lastAt = Date.distantPast
        private let defaultsKey = "recommendation-diag-log"
        private let limit = 80

        init() {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let decoded = try? JSONDecoder().decode(
                [RecommendationDiagEvent].self,
                from: data
               ) {
                events = decoded
            }
        }

        func snapshot() -> [RecommendationDiagEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        func record(_ event: RecommendationDiagEvent) {
            let signature = "\(event.kind.rawValue)|\(event.title)|\(event.detail)"
            lock.lock()
            if signature == lastSignature, event.at.timeIntervalSince(lastAt) < 20 {
                lock.unlock()
                return
            }
            lastSignature = signature
            lastAt = event.at
            events.insert(event, at: 0)
            if events.count > limit {
                events = Array(events.prefix(limit))
            }
            let encoded = try? JSONEncoder().encode(events)
            lock.unlock()
            if let encoded {
                UserDefaults.standard.set(encoded, forKey: defaultsKey)
            }
            NotificationCenter.default.post(name: RecommendationDiagnostics.didChange, object: nil)
        }

        func clear() {
            lock.lock()
            events = []
            lastSignature = ""
            lock.unlock()
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            NotificationCenter.default.post(name: RecommendationDiagnostics.didChange, object: nil)
        }
    }
}
