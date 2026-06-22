import Foundation
import AppKit

actor ClipboardContextMonitor {
    private static let activePollingIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let inactivePollingIntervalNanoseconds: UInt64 = 5_000_000_000

    private var lastChangeCount: Int = -1
    private var lastCapturedText: String?
    private var lastCaptureDate: Date?
    private var monitorTask: Task<Void, Never>?
    private let maximumRetentionWindow: TimeInterval?
    private var isMonitoringEnabled: Bool

    init(maximumRetentionWindow: TimeInterval? = nil, startsEnabled: Bool = true) {
        self.maximumRetentionWindow = maximumRetentionWindow
        self.isMonitoringEnabled = startsEnabled
    }

    deinit {
        monitorTask?.cancel()
    }

    func start() {
        startMonitorIfNeeded()
    }

    func setMonitoringEnabled(_ enabled: Bool) async {
        startMonitorIfNeeded()
        guard isMonitoringEnabled != enabled else { return }
        isMonitoringEnabled = enabled
        if enabled {
            lastChangeCount = await readChangeCount()
        } else {
            lastCapturedText = nil
            lastCaptureDate = nil
        }
    }

    func refreshSnapshot(capturedAt: Date = Date(), matchingChangeCount: Int? = nil) async {
        startMonitorIfNeeded()
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
        let ageAtRecordingStart = referenceDate.timeIntervalSince(captureDate)
        guard ageAtRecordingStart >= 0, ageAtRecordingStart <= window else {
            lastCapturedText = nil
            lastCaptureDate = nil
            return nil
        }
        let recentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (recentText, captureDate)
    }

    func clear() {
        lastCapturedText = nil
        lastCaptureDate = nil
    }

    private func startMonitorIfNeeded() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            await self?.runMonitor()
        }
    }

    private func runMonitor() async {
        lastChangeCount = await readChangeCount()
        while !Task.isCancelled {
            let interval = isMonitoringEnabled
                ? Self.activePollingIntervalNanoseconds
                : Self.inactivePollingIntervalNanoseconds
            try? await Task.sleep(nanoseconds: interval)
            expireStaleCapture()
            guard isMonitoringEnabled else { continue }
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

enum HermesClipboardContextPolicy {
    static let minimumRetentionWindow: TimeInterval = 1
    static let maximumRetentionWindow: TimeInterval = 600
    static let defaultRetentionWindow: TimeInterval = 20
    static let retentionWindow: TimeInterval = defaultRetentionWindow

    static func clampedRetentionWindow(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, minimumRetentionWindow), maximumRetentionWindow)
    }

    static func contextText(_ text: String?,
                            copiedAt: Date,
                            recordingStartedAt: Date,
                            requestSentAt _: Date? = nil,
                            retentionWindow: TimeInterval = retentionWindow) -> String? {
        let ageAtRecordingStart = recordingStartedAt.timeIntervalSince(copiedAt)
        guard ageAtRecordingStart >= 0,
              ageAtRecordingStart <= retentionWindow,
              let recentText = text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return HermesAgentAPIClient.normalizedClipboardText(recentText)
    }
}
