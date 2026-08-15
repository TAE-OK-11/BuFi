import Foundation

enum PersonalizedMixLLM {
    static func apply(
        to mixes: [PersonalizedMix],
        snapshot: HomeSnapshot,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        date: Date = Date()
    ) async -> [PersonalizedMix] {
        let settings = await LyricIntelligenceSettings.load()
        guard settings.provider != .off else { return mixes }
        let family = LyricModelFamily.resolve(settings)
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let month = calendar.component(.month, from: date)
        let today = recent.prefix(8).map { song in
            card(song, lyricIndex: lyricIndex)
        }.joined(separator: "\n")
        var result: [PersonalizedMix] = []
        result.reserveCapacity(mixes.count)
        var remaining = mixes
        if let index = remaining.firstIndex(where: { $0.kind == .daylist }) {
            let daylist = remaining.remove(at: index)
            let refined = await compose(
                mix: daylist,
                family: family,
                settings: settings,
                hour: hour,
                month: month,
                today: today,
                lyricIndex: lyricIndex
            )
            result.append(refined)
        }
        if family != .appleFoundation {
            for kindIDPrefix in ["happy-mix", "chill-mix", "love-mix", "upbeat-mix"] {
                guard let index = remaining.firstIndex(where: {
                    $0.id.hasPrefix(kindIDPrefix)
                }) else { continue }
                let mix = remaining.remove(at: index)
                result.append(
                    await compose(
                        mix: mix,
                        family: family,
                        settings: settings,
                        hour: hour,
                        month: month,
                        today: today,
                        lyricIndex: lyricIndex
                    )
                )
            }
        }
        result.append(contentsOf: remaining)
        return result
    }

    private static func compose(
        mix: PersonalizedMix,
        family: LyricModelFamily,
        settings: LyricIntelligenceSettings,
        hour: Int,
        month: Int,
        today: String,
        lyricIndex: LyricSignatureIndex
    ) async -> PersonalizedMix {
        let brief = PersonalizedMixCatalog.brief(
            forKind: mix.kind,
            mixID: mix.id,
            hour: hour,
            month: month
        )
        let pool = Array(mix.songs.prefix(family.reviewPoolLimit + 8))
        guard pool.count >= 4 else { return mix }
        let prompt = LyricModelPrompts.playlistCompose(
            family: family,
            title: mix.title,
            brief: brief,
            hour: hour,
            month: month,
            today: today.isEmpty ? "(no listens yet today)" : today,
            candidates: pool.enumerated().map { index, song in
                "\(index + 1). \(card(song, lyricIndex: lyricIndex))"
            }.joined(separator: "\n")
        )
        guard let raw = await LyricIntelligenceBackend.complete(
            prompt: prompt,
            settings: settings
        ) else {
            return mix
        }
        let parsed = parse(raw, allowed: Set(pool.map(\.id)))
        guard let ids = parsed.ids, !ids.isEmpty else { return mix }
        var byID = Dictionary(uniqueKeysWithValues: mix.songs.map { ($0.id, $0) })
        var songs: [Song] = []
        for id in ids {
            guard let song = byID.removeValue(forKey: id) else { continue }
            songs.append(song)
        }
        for song in mix.songs where byID.removeValue(forKey: song.id) != nil {
            songs.append(song)
        }
        return PersonalizedMix(
            id: mix.id,
            title: mix.title,
            subtitle: parsed.subtitle?.isEmpty == false ? parsed.subtitle! : mix.subtitle,
            songs: songs,
            kind: mix.kind,
            artworkCoverArt: mix.artworkCoverArt,
            mood: mix.mood.isEmpty ? brief.mood : mix.mood,
            theme: mix.theme.isEmpty ? brief.theme : mix.theme,
            audioFeel: mix.audioFeel.isEmpty ? brief.audioFeel : mix.audioFeel
        )
    }

    static func parse(
        _ raw: String,
        allowed: Set<String>
    ) -> (ids: [String]?, subtitle: String?) {
        let json: String
        if let start = raw.firstIndex(of: "{"),
           let end = raw.lastIndex(of: "}"),
           start < end {
            json = String(raw[start...end])
        } else {
            json = raw
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return (RecommendationLLMReview.parseIDs(raw, allowed: allowed), nil)
        }
        let ids = RecommendationLLMReview.parseIDs(json, allowed: allowed)
        let subtitle = (dictionary["subtitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (ids, subtitle)
    }

    private static func card(_ song: Song, lyricIndex: LyricSignatureIndex) -> String {
        let signature = lyricIndex.bySongID[song.id]
        let moods = signature?.moods.prefix(3).joined(separator: ",") ?? ""
        let vocal = signature?.details.vocalGender ?? ""
        let genre = signature?.details.genre ?? song.genre ?? ""
        return "\(song.id) | \(song.title) — \(song.artist) | \(moods) \(vocal) \(genre)"
    }
}
