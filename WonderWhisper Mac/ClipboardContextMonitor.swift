import Foundation
import AppKit

actor ClipboardContextMonitor {
    private var lastChangeCount: Int = -1
    private var lastCapturedText: String?
    private var lastCaptureDate: Date?
    private var monitorTask: Task<Void, Never>?

    init() {
        monitorTask = Task { [weak self] in
            await self?.runMonitor()
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func consumeClipboardIfRecent(referenceDate: Date, window: TimeInterval) async -> String? {
        guard let captureDate = lastCaptureDate,
              referenceDate.timeIntervalSince(captureDate) <= window,
              let text = lastCapturedText else {
            return nil
        }
        lastCapturedText = nil
        lastCaptureDate = nil
        return text
    }

    func clear() {
        lastCapturedText = nil
        lastCaptureDate = nil
    }

    private func runMonitor() async {
        lastChangeCount = await readChangeCount()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
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
            NSPasteboard.general.changeCount
        }
    }

    private func readClipboardText() async -> String? {
        await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
    }
}
