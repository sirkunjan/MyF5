import Foundation

/// Per-day text and original microphone audio, linked by entry ID.
enum JournalStore {
    static func save(_ text: String, root: URL, date: Date = Date(), id: UUID = UUID(), audio: Data? = nil) throws -> URL {
        let datePath = DateFormatter(); datePath.locale = Locale(identifier: "en_US_POSIX")
        datePath.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("Journal", isDirectory: true)
            .appendingPathComponent(datePath.string(from: date), isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let textFolder = folder.appendingPathComponent("text", isDirectory: true)
        let audioFolder = folder.appendingPathComponent("audio", isDirectory: true)
        for directory in [textFolder, audioFolder] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss ZZZZZ"
        let path = textFolder.appendingPathComponent("journal.md")
        var content = "# Journal · \(day.string(from: date))\n"
        if manager.fileExists(atPath: path.path) { content = try String(contentsOf: path, encoding: .utf8) }
        // The id makes retries idempotent without discarding identical entries
        // spoken at different times.
        let marker = "<!-- entry:\(id.uuidString) -->"
        let audioPath = audioFolder.appendingPathComponent(id.uuidString + ".wav")
        var madeAudio = false
        if !content.contains(marker) {
            if let audio, !manager.fileExists(atPath: audioPath.path) {
                try audio.write(to: audioPath, options: .atomic)
                madeAudio = true
                do { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioPath.path) }
                catch { try? manager.removeItem(at: audioPath); throw error }
            }
            content += "\n\n## \(time.string(from: date))\n\(marker)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            if manager.fileExists(atPath: audioPath.path) {
                content += "\nAudio: [Recording](../audio/\(audioPath.lastPathComponent))\n"
            }
            do { try content.write(to: path, atomically: true, encoding: .utf8) }
            catch { if madeAudio { try? manager.removeItem(at: audioPath) }; throw error }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }
}
