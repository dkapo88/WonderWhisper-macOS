import Foundation
import AppKit

actor ClipboardContextMonitor {
    private var lastChangeCount: Int = -1
    private var lastCapturedText: String?
    private var lastCaptureDate: Date?
    private var monitorTask: Task<Void, Never>?
    private let maximumRetentionWindow: TimeInterval?

    init(maximumRetentionWindow: TimeInterval? = nil) {
        self.maximumRetentionWindow = maximumRetentionWindow
        monitorTask = Task { [weak self] in
            await self?.runMonitor()
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func refreshSnapshot(capturedAt: Date = Date(), matchingChangeCount: Int? = nil) async {
        let changeCount = await readChangeCount()
        if let matchingChangeCount, changeCount != matchingChangeCount {
            return
        }
        guard changeCount != lastChangeCount else {
            expireStaleCapture(referenceDate: capturedAt)
            return
        }
        lastChangeCount = changeCount
        guard let raw = await readClipboardText() else {
            lastCapturedText = nil
            lastCaptureDate = nil
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastCapturedText = nil
            lastCaptureDate = nil
            return
        }
        lastCapturedText = trimmed
        lastCaptureDate = capturedAt
    }

    func consumeClipboardIfRecent(referenceDate: Date, window: TimeInterval) async -> String? {
        guard let snapshot = clipboardSnapshotIfRecent(referenceDate: referenceDate, window: window) else {
            return nil
        }
        lastCapturedText = nil
        lastCaptureDate = nil
        return snapshot.text
    }

    func peekClipboardIfRecent(referenceDate: Date, window: TimeInterval) async -> String? {
        clipboardSnapshotIfRecent(referenceDate: referenceDate, window: window)?.text
    }

    func peekClipboardSnapshotIfRecent(referenceDate: Date,
                                       window: TimeInterval) async -> (text: String, copiedAt: Date)? {
        clipboardSnapshotIfRecent(referenceDate: referenceDate, window: window)
    }

    private func clipboardSnapshotIfRecent(referenceDate: Date,
                                           window: TimeInterval) -> (text: String, copiedAt: Date)? {
        guard let captureDate = lastCaptureDate,
              let text = lastCapturedText else {
            return nil
        }
        guard let recentText = ClipboardContextPolicy.contextText(
            text,
            copiedAt: captureDate,
            recordingStartedAt: referenceDate,
            retentionWindow: window
        ) else {
            lastCapturedText = nil
            lastCaptureDate = nil
            return nil
        }
        return (recentText, captureDate)
    }

    func clear() {
        lastCapturedText = nil
        lastCaptureDate = nil
    }

    private func runMonitor() async {
        lastChangeCount = await readChangeCount()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            expireStaleCapture()
            let changeCount = await readChangeCount()
            guard changeCount != lastChangeCount else { continue }
            lastChangeCount = changeCount
            guard let raw = await readClipboardText() else {
                lastCapturedText = nil
                lastCaptureDate = nil
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                lastCapturedText = nil
                lastCaptureDate = nil
                continue
            }
            lastCapturedText = trimmed
            lastCaptureDate = Date()
        }
    }

    private func readChangeCount() async -> Int {
        await MainActor.run {
            do {
                let result = try ObjCExceptionHandler.catchException {
                    NSPasteboard.general.changeCount as NSNumber
                }
                return (result as? NSNumber)?.intValue ?? -1
            } catch {
                return -1
            }
        }
    }

    private func readClipboardText() async -> String? {
        await MainActor.run {
            do {
                let result = try ObjCExceptionHandler.catchException {
                    NSPasteboard.general.string(forType: .string) as NSString?
                }
                return result as? String
            } catch {
                return nil
            }
        }
    }

    private func expireStaleCapture(referenceDate: Date = Date()) {
        guard let maximumRetentionWindow,
              let captureDate = lastCaptureDate,
              referenceDate.timeIntervalSince(captureDate) > maximumRetentionWindow else {
            return
        }
        lastCapturedText = nil
        lastCaptureDate = nil
    }
}

enum ClipboardContextPolicy {
    static func contextText(_ text: String?,
                            copiedAt: Date,
                            recordingStartedAt: Date,
                            retentionWindow: TimeInterval) -> String? {
        let ageAtRecordingStart = recordingStartedAt.timeIntervalSince(copiedAt)
        guard ageAtRecordingStart >= 0,
              ageAtRecordingStart <= retentionWindow else {
            return nil
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HermesClipboardContextPolicy {
    static let minimumRetentionWindow: TimeInterval = 1
    static let maximumRetentionWindow: TimeInterval = 600
    static let defaultRetentionWindow: TimeInterval = 60
    static let retentionWindow: TimeInterval = defaultRetentionWindow

    static func clampedRetentionWindow(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, minimumRetentionWindow), maximumRetentionWindow)
    }

    static func contextText(_ text: String?,
                            copiedAt: Date,
                            recordingStartedAt: Date,
                            requestSentAt _: Date? = nil,
                            retentionWindow: TimeInterval = retentionWindow) -> String? {
        guard let recentText = ClipboardContextPolicy.contextText(
            text,
            copiedAt: copiedAt,
            recordingStartedAt: recordingStartedAt,
            retentionWindow: retentionWindow
        ) else {
            return nil
        }
        return HermesAgentAPIClient.normalizedClipboardText(recentText)
    }
}
