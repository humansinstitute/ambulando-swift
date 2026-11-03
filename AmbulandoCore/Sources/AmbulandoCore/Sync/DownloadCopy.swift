import Foundation

/// Copies verified bytes to a user-visible destination without replacing an existing file.
public enum DownloadCopy {
    public static func save(_ source: URL, name: String, directory: URL) throws -> URL {
        let safe = name.replacingOccurrences(of: "[/\\\\:\\x00-\\x1f]", with: "_", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let filename = (safe.isEmpty || safe == "." || safe == "..") ? "file" : safe
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for index in 0..<10000 {
            try Task.checkCancellation()
            let suffix = index == 0 ? "" : " (\(index))"
            let candidate = directory.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            do {
                try FileManager.default.copyItem(at: source, to: candidate)
                return candidate
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
