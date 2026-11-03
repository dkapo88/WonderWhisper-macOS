import Foundation

/// The webhook editor's unsaved state: the endpoint fields and the custom header drafts, plus
/// what happened when a MausBot address was pasted. Nothing here touches the Keychain or the
/// saved endpoints; the sheet saves it on Save and drops it on Cancel.
struct MeetingWebhookEditorDraft: Equatable {
  struct Header: Identifiable, Equatable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
      self.id = id
      self.name = name
      self.value = value
    }
  }

  /// The Authorization draft filled from a pasted MausBot address, and the destination that
  /// address pointed to, so the header is cleared again if the URL then points elsewhere.
  struct MovedSecret: Equatable {
    let headerID: UUID
    let value: String
    let destination: String
  }

  let isNew: Bool
  var endpoint: MeetingWebhookEndpoint
  var headers: [Header]
  private(set) var movedSecret: MovedSecret?
  /// The MausBot delivery settings were applied to this new draft; never applied twice.
  private(set) var appliedMausBotDefaults = false

  init(endpoint: MeetingWebhookEndpoint, isNew: Bool, headers: [Header] = []) {
    self.endpoint = endpoint
    self.isNew = isNew
    self.headers = headers
  }

  /// A secret was moved from a pasted MausBot address and its header draft is still as filled.
  var showsMausBotBadge: Bool {
    guard let movedSecret else { return false }
    return headers.contains { $0.id == movedSecret.headerID && $0.value == movedSecret.value }
  }

  /// The "MausBot settings applied" line: shown while the badge is.
  var showsMausBotDefaults: Bool {
    appliedMausBotDefaults && showsMausBotBadge
  }

  /// The URL now points at a MausBot hook (with or without its secret).
  var isMausBotURL: Bool {
    MeetingWebhookMausBotAddress.matches(endpoint.url)
  }

  /// Call after the URL field changed. A complete MausBot address moves its secret into a
  /// masked Authorization draft at once (replacing any Authorization draft, whatever its case)
  /// and takes the secret out of the URL; on a new webhook it also applies the MausBot
  /// delivery settings, once. Pointing the URL at any other destination afterwards clears an
  /// Authorization draft filled that way (unless it was edited since). Anything else, such as
  /// a partly typed secret, is left alone.
  mutating func urlChanged() {
    if let extracted = MeetingWebhookMausBotAddress.extract(from: endpoint.url) {
      moveSecret(extracted)
      return
    }
    guard let moved = movedSecret,
          MeetingWebhookMausBotAddress.destination(of: endpoint.url) != moved.destination else {
      return
    }
    headers.removeAll { $0.id == moved.headerID && $0.value == moved.value }
    movedSecret = nil
  }

  /// The headers to save: trimmed, blank rows dropped. Returns an error message for a row with
  /// only a name or only a value.
  func editedHeaders() -> Result<[String: String], HeaderError> {
    var result: [String: String] = [:]
    for draft in headers {
      let name = draft.name.trimmingCharacters(in: .whitespaces)
      let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty || !value.isEmpty else { continue }
      guard !name.isEmpty else {
        return .failure(HeaderError("Every header value needs a header name."))
      }
      guard !value.isEmpty else {
        return .failure(HeaderError("Header \(name) needs a value."))
      }
      result[name] = value
    }
    return .success(result)
  }

  struct HeaderError: Error, Equatable {
    let message: String

    init(_ message: String) {
      self.message = message
    }
  }

  static func isAuthorization(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespaces).lowercased()
      == MeetingWebhookMausBotAddress.authorizationHeader.lowercased()
  }

  /// The MausBot delivery settings: the full note, split, 40,000 bytes, 30 s and 30 s.
  static func applyMausBotDefaults(to endpoint: inout MeetingWebhookEndpoint) {
    endpoint.content = .full
    endpoint.splitIntoParts = true
    endpoint.maxBodyCharacters = MeetingWebhookMausBotAddress.defaultMaxBodyBytes
    endpoint.partDelaySeconds = MeetingWebhookMausBotAddress.defaultPartDelaySeconds
    endpoint.noteDelaySeconds = MeetingWebhookMausBotAddress.defaultNoteDelaySeconds
  }

  private mutating func moveSecret(_ extracted: MeetingWebhookMausBotAddress.Extracted) {
    // The new header takes the place of the first Authorization draft, or goes last.
    let position = headers.firstIndex { Self.isAuthorization($0.name) }
    headers.removeAll { Self.isAuthorization($0.name) }
    let draft = Header(
      name: MeetingWebhookMausBotAddress.authorizationHeader,
      value: extracted.authorizationValue
    )
    headers.insert(draft, at: min(position ?? headers.count, headers.count))
    movedSecret = MovedSecret(
      headerID: draft.id,
      value: draft.value,
      destination: MeetingWebhookMausBotAddress.destination(of: extracted.url) ?? extracted.url
    )
    if isNew && !appliedMausBotDefaults {
      Self.applyMausBotDefaults(to: &endpoint)
      appliedMausBotDefaults = true
    }
    endpoint.url = extracted.url
  }
}
