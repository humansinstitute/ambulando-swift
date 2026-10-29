import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Browser files never enter Tower storage or the identity bridge. WebKit owns request cookies/redirects.
struct BrowserDownloadFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws { bytes = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}

@MainActor
final class BrowserDownloadTransfer: NSObject, WKDownloadDelegate {
    nonisolated static let limit: Int64 = 100 * 1024 * 1024
    weak var model: BrowserModel?
    weak var tab: BrowserTab?
    let download: WKDownload
    private var destination: URL?
    private var directory: URL?
    private var observation: NSKeyValueObservation?
    private var stopped = false

    init(download: WKDownload, model: BrowserModel, tab: BrowserTab) {
        self.download = download; self.model = model; self.tab = tab
        super.init()
        download.delegate = self
        observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let count = progress.completedUnitCount
            Task { @MainActor in if count > Self.limit { self?.cancel("Download exceeds the 100 MB limit.") } }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard !stopped, let model, model.presented, tab?.closed == false,
              response.expectedContentLength <= Self.limit else {
            cancel("Download unavailable or exceeds the 100 MB limit."); return nil
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            cancel("Download failed (HTTP \(http.statusCode))."); return nil
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ambulando-browser-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
                .filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && $0 != ":" && $0 != "/" }
            let file = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : String(name.prefix(180)))
            destination = file
            return file
        } catch { cancel("Could not prepare the downloaded file."); return nil }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard let url = request.url, url.scheme == "https", BrowserURLPolicy.decide(url, mainFrame: true) == .load else {
            decisionHandler(.cancel); cancel("Download redirected to an unsupported address."); return
        }
        decisionHandler(.allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !stopped, let destination, let model, model.presented, tab?.closed == false else { cleanup(); return }
        Task {
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= Self.limit else { throw CocoaError(.fileReadTooLarge) }
                    return try Data(contentsOf: destination)
                }.value
                guard !stopped, model.presented, tab?.closed == false else { cleanup(); return }
                model.downloadFile = BrowserDownloadFile(bytes: bytes)
                model.downloadFilename = destination.lastPathComponent
                model.exportingDownload = true
            } catch { tab?.refusal = "Could not read the downloaded file: \(error.localizedDescription)" }
            cleanup()
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if !stopped { tab?.refusal = (error as? URLError)?.code == .cancelled ? "Download cancelled." : "Download failed: \(error.localizedDescription)" }
        cleanup()
    }

    func cancel(_ message: String = "Download cancelled.") {
        guard !stopped else { return }
        stopped = true
        download.cancel { _ in }
        tab?.refusal = message
        cleanup()
    }

    private func cleanup() {
        observation?.invalidate(); observation = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if model?.downloadTransfer === self { model?.downloadTransfer = nil }
    }
}
