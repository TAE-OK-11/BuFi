import Foundation

/// Form-style server query parsers interpret a literal plus as a space.
/// URLComponents follows URI encoding rules instead, so protect literal pluses
/// after its normal escaping without re-encoding percent escapes or separators.
enum OpenSubsonicRequestEncoding {
    static func query(_ items: [URLQueryItem]) -> String? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    static func protectingLiteralPluses(in url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery,
              query.contains("+") else { return url }
        components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }
}
