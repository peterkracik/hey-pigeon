// Crash and hang reports, kept on the device. MetricKit hands the app a
// diagnostic payload (crashes, hangs, CPU and disk exceptions, with their
// call stacks) soon after one happened — a crash's at the next launch;
// the app has no backend to send it to and never will, so it writes each
// as a JSON file next to its store and Settings › Diagnostics lists them,
// to copy into an issue or delete. Nothing leaves the device unless the
// user copies it out: the folder is kept out of iCloud and Finder backups.

import Foundation
import MetricKit

final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsCollector()
    /// The newest reports kept; older ones are deleted.
    static let limit = 20

    private var started = false
    private let lock = NSLock()

    /// Subscribe once. Not in the sample inbox or the tests.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    /// Called by the system on a queue of its own.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Self.store(payload.jsonRepresentation(), at: payload.timeStampEnd)
        }
    }

    // MARK: The files

    static var directory: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HeyPigeon", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static func store(_ json: Data, at date: Date, in directory: URL? = DiagnosticsCollector.directory) {
        guard var directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // "Kept on this device" has to be true of its backups too.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        let name = "diagnostic-\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
        try? json.write(to: directory.appendingPathComponent(name), options: .atomic)
        for old in reports(in: directory).dropFirst(limit) { try? FileManager.default.removeItem(at: old.url) }
    }

    struct Report: Identifiable, Hashable {
        let url: URL
        let date: Date
        let bytes: Int
        var id: URL { url }
    }

    /// The stored reports, newest first.
    static func reports(in directory: URL? = DiagnosticsCollector.directory) -> [Report] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Report(url: url, date: values?.contentModificationDate ?? .distantPast, bytes: values?.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    static func deleteAll(in directory: URL? = DiagnosticsCollector.directory) {
        for report in reports(in: directory) { try? FileManager.default.removeItem(at: report.url) }
    }
}
