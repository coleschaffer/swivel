import AppKit
import ServiceManagement

/// A small log at ~/Library/Logs/Swivel.log: timings and problems, never window titles or contents.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Swivel.log")

    static func write(_ message: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let line = Data("\(stamp) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Starts over once the log passes half a megabyte.
    static func trim() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 512_000 { try? FileManager.default.removeItem(at: url) }
    }
}

/// Opening Swivel at login: as a regular login item, or through a LaunchAgent if macOS won't register one.
@MainActor
enum LoginItem {
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.swivel.Swivel.plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        if enabled && status != .enabled && status != .requiresApproval {
            installAgent()
        } else {
            try? FileManager.default.removeItem(at: agentURL)
        }
        Log.write("login item: \(isEnabled ? "on" : needsApproval ? "waiting for approval" : "off") (status \(status.rawValue))")
    }

    private static func installAgent() {
        let agent: NSDictionary = ["Label": "local.swivel.Swivel",
                                   "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                                   "RunAtLoad": true]
        try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        agent.write(to: agentURL, atomically: true)
    }
}
