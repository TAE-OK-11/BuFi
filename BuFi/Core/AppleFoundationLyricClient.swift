import Foundation

enum ApplePrivateCloudStatus: Equatable, Sendable {
    case needsIOS27
    case deviceNotEligible
    case systemNotReady
    case quotaReached
    case available
    case unavailable

    var showsInSettings: Bool {
        switch self {
        case .needsIOS27, .deviceNotEligible:
            return false
        case .systemNotReady, .quotaReached, .available, .unavailable:
            return true
        }
    }

    var title: String {
        switch self {
        case .needsIOS27:
            String(localized: "Apple Privacy Cloud: iOS 27 이상 필요")
        case .deviceNotEligible:
            String(localized: "Apple Privacy Cloud: 이 기기는 미지원")
        case .systemNotReady:
            String(localized: "Apple Privacy Cloud: 아직 준비되지 않음")
        case .quotaReached:
            String(localized: "Apple Privacy Cloud: 오늘 한도 초과")
        case .available:
            String(localized: "Apple Privacy Cloud: 사용 가능")
        case .unavailable:
            String(localized: "Apple Privacy Cloud: 지금은 사용 불가")
        }
    }

    var settingsNote: String {
        switch self {
        case .needsIOS27:
            String(localized: "Apple Privacy Cloud는 iOS 27 이상이 필요합니다.")
        case .deviceNotEligible:
            String(localized: "이 기기는 Apple Privacy Cloud를 지원하지 않습니다.")
        case .systemNotReady:
            String(localized: "Apple Privacy Cloud가 아직 준비되지 않았습니다. 네트워크와 Apple Intelligence 설정을 확인하세요.")
        case .quotaReached:
            String(localized: "오늘 Apple Privacy Cloud 사용량을 모두 썼습니다. 지금은 기기 모델로 분석합니다.")
        case .available:
            String(localized: "가사를 Apple Private Cloud Compute로 분석합니다. 가사는 기기를 떠나 Apple 프라이버시 클라우드에서만 처리되며, 하루 사용량 제한이 있습니다. 쓸 수 없으면 Apple 3B 로컬로 넘어갑니다.")
        case .unavailable:
            String(localized: "지금은 Apple Privacy Cloud를 쓸 수 없습니다. Apple 3B 로컬로 대체합니다.")
        }
    }

    var usesLocal3BFallback: Bool {
        self != .available
    }
}

/// Uses every on-device Apple Intelligence adapter that fits lyrics:
/// content tagging for moods/themes, then the default AFM for energy/valence.
/// Gemma 3 270M is only the fallback when both adapters fail.
/// Apple Privacy Cloud (Private Cloud Compute) is opt-in from Settings
/// on iOS 27+ devices that expose the server model.
enum AppleOnDeviceModelStatus: Equatable, Sendable {
    case needsIOS26
    case available
    case unavailable

    var title: String {
        switch self {
        case .needsIOS26:
            String(localized: "기기 Apple Intelligence: iOS 26 이상 필요")
        case .available:
            String(localized: "기기 Apple Intelligence: 사용 가능")
        case .unavailable:
            String(localized: "기기 Apple Intelligence: 꺼져 있거나 이 기기에서 사용 불가")
        }
    }
}

enum AppleFoundationLyricClient {
    struct Analysis: Sendable {
        var moods: [String]
        var themes: [String]
        var energy: Double
        var valence: Double
        var summary: String
        var source: String
    }

    static func onDeviceStatus() -> AppleOnDeviceModelStatus {
        if #available(iOS 26.0, *) {
            return FoundationModelsBridge.status()
        }
        return .needsIOS26
    }

    static func privateCloudStatus() -> ApplePrivateCloudStatus {
        if #available(iOS 27.0, *) {
            return PrivateCloudBridge.status()
        }
        return .needsIOS27
    }

    static var showsPrivateCloudSetting: Bool {
        privateCloudStatus().showsInSettings
    }

    static func analyze(lyrics: String) async -> Analysis? {
        if #available(iOS 26.0, *) {
            return await FoundationModelsBridge.analyze(lyrics: lyrics)
        }
        return nil
    }

    static func analyzePrivateCloud(lyrics: String) async -> Analysis? {
        if #available(iOS 27.0, *) {
            return await PrivateCloudBridge.analyze(lyrics: lyrics)
        }
        return nil
    }

    static func analyzeLocal3B(lyrics: String) async -> Analysis? {
        if #available(iOS 26.0, *) {
            return await FoundationModelsBridge.analyzeDefault3B(lyrics: lyrics)
        }
        return nil
    }

    static func analyzePrivateCloudOrLocal3B(lyrics: String) async -> Analysis? {
        if !privateCloudStatus().usesLocal3BFallback,
           let cloud = await analyzePrivateCloud(lyrics: lyrics) {
            return cloud
        }
        if let local = await analyzeLocal3B(lyrics: lyrics) {
            return local
        }
        return await analyze(lyrics: lyrics)
    }

    static func complete(_ prompt: String) async -> String? {
        if #available(iOS 26.0, *) {
            return await FoundationModelsBridge.complete(prompt)
        }
        return nil
    }

    static func completePrivateCloud(_ prompt: String) async -> String? {
        if #available(iOS 27.0, *) {
            return await PrivateCloudBridge.complete(prompt)
        }
        return nil
    }

    static func completePrivateCloudOrLocal3B(_ prompt: String) async -> String? {
        if !privateCloudStatus().usesLocal3BFallback,
           let cloud = await completePrivateCloud(prompt) {
            return cloud
        }
        return await complete(prompt)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
private enum FoundationModelsBridge {
    static func status() -> AppleOnDeviceModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        default:
            return .unavailable
        }
    }

    static func analyze(lyrics: String) async -> AppleFoundationLyricClient.Analysis? {
        async let tagged = respond(
            to: LyricIntelligencePrompt.tagging(lyrics: lyrics),
            useCase: .contentTagging
        )
        async let scored = respond(
            to: LyricIntelligencePrompt.scales(lyrics: lyrics),
            useCase: nil
        )
        let parts = await (tagged, scored)

        let tagParse = parts.0.flatMap(LyricIntelligencePrompt.parse)
        let scoreParse = parts.1.flatMap(LyricIntelligencePrompt.parse)

        let moods = tagParse?.moods ?? scoreParse?.moods ?? []
        let themes = tagParse?.themes ?? scoreParse?.themes ?? []
        let energy = scoreParse?.energy ?? tagParse?.energy ?? 0.5
        let valence = scoreParse?.valence ?? tagParse?.valence ?? 0.5
        let summary = tagParse?.summary ?? scoreParse?.summary ?? ""
        guard !moods.isEmpty || parts.1 != nil || !summary.isEmpty else { return nil }
        let resolvedMoods = moods.isEmpty ? ["neutral"] : moods

        let source: String
        switch (parts.0 != nil, parts.1 != nil) {
        case (true, true):
            source = "apple-intelligence-tagging+default"
        case (true, false):
            source = "apple-intelligence-tagging"
        default:
            source = "apple-intelligence"
        }
        return AppleFoundationLyricClient.Analysis(
            moods: resolvedMoods,
            themes: themes,
            energy: energy,
            valence: valence,
            summary: summary,
            source: source
        )
    }

    static func analyzeDefault3B(lyrics: String) async -> AppleFoundationLyricClient.Analysis? {
        guard let text = await respond(
            to: LyricIntelligencePrompt.moodAnalysis(lyrics: lyrics),
            useCase: nil
        ), let parsed = LyricIntelligencePrompt.parse(text) else {
            return nil
        }
        return AppleFoundationLyricClient.Analysis(
            moods: parsed.moods.isEmpty ? ["neutral"] : parsed.moods,
            themes: parsed.themes,
            energy: parsed.energy,
            valence: parsed.valence,
            summary: parsed.summary,
            source: "apple-intelligence-3b"
        )
    }

    static func complete(_ prompt: String) async -> String? {
        await respond(to: prompt, useCase: nil)
    }

    private static func respond(
        to prompt: String,
        useCase: SystemLanguageModel.UseCase?
    ) async -> String? {
        do {
            let model = useCase.map { SystemLanguageModel(useCase: $0) }
                ?? SystemLanguageModel.default
            let session = LanguageModelSession(model: model)
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
    static func status() -> AppleOnDeviceModelStatus {
        .unavailable
    }

    static func analyze(lyrics: String) async -> AppleFoundationLyricClient.Analysis? {
        _ = lyrics
        return nil
    }

    static func analyzeDefault3B(lyrics: String) async -> AppleFoundationLyricClient.Analysis? {
        _ = lyrics
        return nil
    }

    static func complete(_ prompt: String) async -> String? {
        _ = prompt
        return nil
    }
}
#endif

#if canImport(FoundationModels)
@available(iOS 27.0, *)
private enum PrivateCloudBridge {
    static func status() -> ApplePrivateCloudStatus {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            if model.quotaUsage.isLimitReached {
                return .quotaReached
            }
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.systemNotReady):
            return .systemNotReady
        default:
            return .unavailable
        }
    }

    static func analyze(lyrics: String) async -> AppleFoundationLyricClient.Analysis? {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            break
        default:
            return nil
        }
        if model.quotaUsage.isLimitReached {
            return nil
        }
        do {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(
                to: LyricIntelligencePrompt.moodAnalysis(
                    lyrics: lyrics,
                    characterLimit: 12_000
                )
            )
            guard let parsed = LyricIntelligencePrompt.parse(response.content) else {
                return nil
            }
            return AppleFoundationLyricClient.Analysis(
                moods: parsed.moods.isEmpty ? ["neutral"] : parsed.moods,
                themes: parsed.themes,
                energy: parsed.energy,
                valence: parsed.valence,
                summary: parsed.summary,
                source: "apple-privacy-cloud"
            )
        } catch {
            return nil
        }
    }

    static func complete(_ prompt: String) async -> String? {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            break
        default:
            return nil
        }
        if model.quotaUsage.isLimitReached {
            return nil
        }
        do {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            return nil
        }
    }
}
#else
@available(iOS 27.0, *)
private enum PrivateCloudBridge {
    static func status() -> ApplePrivateCloudStatus {
        .unavailable
    }

    static func analyze(lyrics: String) async -> AppleFoundationLyricClient.Analysis? {
        _ = lyrics
        return nil
    }

    static func complete(_ prompt: String) async -> String? {
        _ = prompt
        return nil
    }
}
#endif
