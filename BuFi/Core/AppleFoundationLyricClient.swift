import Foundation

/// Device-first lyric analysis. Apple Intelligence runs when the
/// system model is present; otherwise the caller falls back to Gemma 3 270M.
enum AppleFoundationLyricClient {
    static func complete(_ prompt: String) async -> String? {
        if #available(iOS 26.0, *) {
            return await FoundationModelsBridge.complete(prompt)
        }
        return nil
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
private enum FoundationModelsBridge {
    static func complete(_ prompt: String) async -> String? {
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            return nil
        }
    }
}
#else
@available(iOS 26.0, *)
private enum FoundationModelsBridge {
    static func complete(_ prompt: String) async -> String? {
        _ = prompt
        return nil
    }
}
#endif
