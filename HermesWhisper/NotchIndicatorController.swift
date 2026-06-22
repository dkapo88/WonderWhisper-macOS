import AppKit

enum OverlayScreenResolver {
    @MainActor
    static func activeScreen() -> NSScreen? {
        screenContainingFrontmostWindow() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func screenContainingFrontmostWindow() -> NSScreen? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        let pid = frontmost.processIdentifier
        let frontmostWindows = windowInfo.compactMap { info -> CGRect? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == pid else {
                return nil
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return nil }

            if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0 {
                return nil
            }

            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 80,
                  bounds.height >= 60 else {
                return nil
            }
            return bounds
        }

        guard let largestWindow = frontmostWindows.max(by: { $0.area < $1.area }) else {
            return nil
        }
        return screen(containingQuartzFrame: largestWindow)
    }

    private static func screen(containingQuartzFrame frame: CGRect) -> NSScreen? {
        var bestMatch: (screen: NSScreen, area: CGFloat)?

        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let displayFrame = CGDisplayBounds(displayID)
            let intersection = displayFrame.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.area

            if area > (bestMatch?.area ?? 0) {
                bestMatch = (screen, area)
            }
        }

        guard let bestMatch, bestMatch.area > 0 else { return nil }
        return bestMatch.screen
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
