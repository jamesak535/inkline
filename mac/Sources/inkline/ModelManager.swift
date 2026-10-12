import Foundation

/// Manages local model files: the models directory, the installed list, the
/// active selection, and downloading new models.
///
/// The download *mechanism* is platform-native (URLSession here; a native
/// downloader on Windows) — file fetching is a platform service where native APIs
/// are the right tool. The curated catalog and the UI that drives this live in the
/// shared front-end (`ui/settings.html`), so the cross-platform part stays shared.
final class ModelManager: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelManager()

    private let activeKey = "InklineModelPath"
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionDownloadTask?
    private var downloadName: String?
    private var moveError: String?
    private var cancelled = false

    /// Download callbacks, always invoked on the main thread.
    var onProgress: ((_ name: String, _ received: Int64, _ total: Int64) -> Void)?
    var onFinished: ((_ name: String, _ error: String?, _ cancelled: Bool) -> Void)?

    /// Fallback models dir: `~/Library/Application Support/Inkline/models`.
    private let defaultDir: URL

    /// The active models directory — the user's chosen folder (Settings) or the
    /// default — created on access. Where downloads land and the UI lists from.
    var modelsDir: URL {
        let dir = Settings.modelsDirectory.map { URL(fileURLWithPath: $0) } ?? defaultDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        defaultDir = base.appendingPathComponent("Inkline/models", isDirectory: true)
        super.init()
    }

    struct Model { let name: String; let path: String; let size: Int64; let active: Bool }

    /// Installed models in the models dir, plus the active model if it lives
    /// elsewhere (e.g. a dev model set via `INKLINE_MODEL`). Sorted by name.
    func installed() -> [Model] {
        let active = UserDefaults.standard.string(forKey: activeKey)
        var seen = Set<String>()
        var models: [Model] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for url in files where url.pathExtension.lowercased() == "gguf" {
            seen.insert(url.path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            models.append(Model(name: url.lastPathComponent, path: url.path, size: size, active: url.path == active))
        }
        if let active, !active.isEmpty, !seen.contains(active),
           FileManager.default.fileExists(atPath: active) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: active))?[.size] as? NSNumber)?.int64Value ?? 0
            models.append(Model(name: (active as NSString).lastPathComponent, path: active, size: size, active: true))
        }
        return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The active model path to load at launch: the explicit selection
    /// (UserDefaults) if it still exists, else the first installed model (which is
    /// then persisted as the choice). `nil` if there are no models at all.
    func activeModelPath() -> String? {
        if let path = UserDefaults.standard.string(forKey: activeKey),
           !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return path
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        if let first = files.first(where: { $0.pathExtension.lowercased() == "gguf" })?.path {
            UserDefaults.standard.set(first, forKey: activeKey)
            return first
        }
        return nil
    }

    /// Make `path` the active model: persist the choice and (re)load it in the core.
    func activate(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        UserDefaults.standard.set(path, forKey: activeKey)
        CoreBridge.shared.setModel(path)
    }

    var isDownloading: Bool { task != nil }

    /// Start downloading a `.gguf` from `urlString` into the models dir. One at a
    /// time. Returns the destination filename, or `nil` if rejected (bad URL, not
    /// a `.gguf`, or a download is already running).
    @discardableResult
    func startDownload(_ urlString: String) -> String? {
        guard task == nil,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".gguf"), !name.contains("/"), !name.contains("..") else {
            return nil
        }
        downloadName = name
        moveError = nil
        cancelled = false
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
        return name
    }

    /// Cancel the active download, if any.
    func cancelDownload() {
        cancelled = true
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate (called on the session's background queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let name = downloadName ?? ""
        DispatchQueue.main.async { self.onProgress?(name, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is removed once this returns, so move it synchronously here.
        let dest = modelsDir.appendingPathComponent(downloadName ?? location.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            moveError = "couldn't save file: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let name = downloadName ?? ""
        let wasCancelled = cancelled || (error as NSError?)?.code == NSURLErrorCancelled
        let message = wasCancelled ? nil : (error?.localizedDescription ?? moveError)
        self.task = nil
        downloadName = nil
        moveError = nil
        cancelled = false
        DispatchQueue.main.async { self.onFinished?(name, message, wasCancelled) }
    }
}
