import Foundation

/// Encoding and file I/O stay on this utility actor, never the UI executor.
actor NavigationReportExporter {
    private let destination: URL

    init(destination: URL) { self.destination = destination }

    func write(_ report: NavigationPerformance.Report) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
