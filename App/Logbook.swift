import Foundation
import Combine

/// In-memory + on-disk protocol log. The file survives app restarts so background events
/// (calls, Shortcuts) can be inspected later and shared for debugging.
final class Logbook: ObservableObject {
    static let shared = Logbook()

    struct Line: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var lines: [Line] = []

    let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("fit3bridge-log.txt")
    }()

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    func add(_ text: String) {
        let line = Line(date: Date(), text: text)
        let write = { [self] in
            lines.append(line)
            if lines.count > 600 { lines.removeFirst(lines.count - 600) }
            appendToFile("\(formatter.string(from: line.date))  \(text)\n")
        }
        if Thread.isMainThread { write() } else { DispatchQueue.main.async(execute: write) }
        #if DEBUG
        print("[Fit3] \(text)")
        #endif
    }

    func format(_ line: Line) -> String { formatter.string(from: line.date) }

    func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func appendToFile(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > 2_000_000 {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
