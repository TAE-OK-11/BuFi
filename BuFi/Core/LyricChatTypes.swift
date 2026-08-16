import Foundation

/// Parsed model-side tool call metadata. The actual tool execution path was
/// removed, but chat response parsing and its regression tests still need to
/// recognize tool-call replies without invoking them.
struct LyricToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

enum LyricChatReply: Equatable, Sendable {
    case text(String)
    case tools([LyricToolCall])
}
