import AppKit
import Foundation

enum MeetingObsidianExporter {
  static func export(session: MeetingSession, to folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let filename = uniqueFilename(for: session, in: folder)
    let destination = folder.appendingPathComponent(filename)
    let markdown = document(for: session)
    try Data(markdown.utf8).write(to: destination, options: .atomic)
    return destination
  }

  static func document(for session: MeetingSession) -> String {
    let iso = ISO8601DateFormatter().string(from: session.startedAt)
    let durationMinutes = max(1, Int((session.duration / 60).rounded()))
    let source = session.detectedApp ?? "Manual"
    let escapedTitle = yamlDoubleQuoted(session.title)
    let escapedSource = yamlDoubleQuoted(source)
    let notes = session.notesMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
    let notesSection: String
    if let notes, !notes.isEmpty {
      notesSection = notes
    } else {
      notesSection = """
      ## Summary

      _Summary generation was not available._

      ## Decisions

      - None captured.

      ## Action items

      - None captured.
      """
    }
    let transcript = session.transcriptMarkdown.isEmpty
      ? "_No transcript was captured._"
      : session.transcriptMarkdown

    return """
    ---
    title: \(escapedTitle)
    date: \(iso)
    source: \(escapedSource)
    duration_minutes: \(durationMinutes)
    tags:
      - meeting
    ---

    # \(session.title)

    \(notesSection)

    ## Transcript

    \(transcript)
    """
  }

  static func open(_ url: URL) {
    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: url.path)]
    if let obsidianURL = components.url {
      NSWorkspace.shared.open(obsidianURL)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  static func yamlDoubleQuoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
  }

  private static func uniqueFilename(for session: MeetingSession, in folder: URL) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    let base = "\(formatter.string(from: session.startedAt)) — \(sanitized(session.title))"
    var candidate = "\(base).md"
    var suffix = 2
    while FileManager.default.fileExists(
      atPath: folder.appendingPathComponent(candidate).path
    ) {
      candidate = "\(base) \(suffix).md"
      suffix += 1
    }
    return candidate
  }

  private static func sanitized(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(120))
  }
}

struct MeetingGeneratedNotes: Equatable, Sendable {
  let title: String?
  let markdown: String
}

struct MeetingNoteGenerator {
  func generate(transcript: String, model: String) async throws -> MeetingGeneratedNotes {
    let provider = OpenRouterLLMProvider(
      client: OpenRouterHTTPClient(apiKeyProvider: {
        KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias)
      })
    )
    let settings = LLMSettings(
      endpoint: AppConfig.openrouterChatCompletions,
      model: model,
      systemPrompt: """
      You create concise, factual meeting notes from a transcript. Never invent details.
      Begin with `TITLE: <a specific meeting title of at most 8 words>`, then a blank line.
      After that, return Markdown with exactly these headings: ## Summary, ## Decisions,
      ## Action items, and ## Key references. Use bullets where useful. Preserve ticket IDs,
      names, dates, owners, and deadlines exactly. If a section has no evidence, write "None captured."
      """,
      timeout: 120,
      streaming: false,
      temperature: 0.1,
      openRouterReasoning: .off
    )
    let response = try await provider.process(
      text: transcript,
      userPrompt: "Create the final meeting notes now.",
      settings: settings
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return Self.parse(response)
  }

  static func parse(_ response: String) -> MeetingGeneratedNotes {
    let trimmed = strippingOptionalMarkdownFence(response)
    guard let lineEnd = trimmed.firstIndex(of: "\n") else {
      if trimmed.uppercased().hasPrefix("TITLE:") {
        return MeetingGeneratedNotes(
          title: normalizedTitle(String(trimmed.dropFirst("TITLE:".count))),
          markdown: ""
        )
      }
      return MeetingGeneratedNotes(title: nil, markdown: trimmed)
    }

    let firstLine = String(trimmed[..<lineEnd])
    guard firstLine.uppercased().hasPrefix("TITLE:") else {
      return MeetingGeneratedNotes(title: nil, markdown: trimmed)
    }
    let markdown = String(trimmed[trimmed.index(after: lineEnd)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return MeetingGeneratedNotes(
      title: normalizedTitle(String(firstLine.dropFirst("TITLE:".count))),
      markdown: markdown
    )
  }

  private static func normalizedTitle(_ raw: String) -> String? {
    let title = raw
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\"'`")
      ))
    guard !title.isEmpty else { return nil }
    return title
      .split(whereSeparator: \.isWhitespace)
      .prefix(8)
      .joined(separator: " ")
      .prefix(100)
      .description
  }

  private static func strippingOptionalMarkdownFence(_ response: String) -> String {
    var trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    if let firstLineEnd = trimmed.firstIndex(of: "\n") {
      trimmed = String(trimmed[trimmed.index(after: firstLineEnd)...])
    }
    if trimmed.hasSuffix("```") {
      trimmed.removeLast(3)
    }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
