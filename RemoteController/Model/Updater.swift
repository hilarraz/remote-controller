import AppKit
import Foundation

/// Installs newer versions of Remote from the repository's GitHub releases, which the
/// release workflow publishes for each version tag. The repository is private, so
/// requests use the token of the GitHub CLI logged in on this Mac (`gh auth login`).
@MainActor
final class Updater {
    static let shared = Updater()

    static let repository = "hilarraz/remote-controller"
    static let automaticCheckKey = "checkForUpdatesAutomatically"
    private static let lastCheckKey = "lastUpdateCheck"

    private var isChecking = false

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            /// API URL of the asset, which serves the file to authenticated requests.
            let url: URL
        }

        let tagName: String
        let body: String?
        let assets: [Asset]

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    enum UpdateError: LocalizedError {
        case noGitHubCLI
        case notLoggedIn
        case noRelease
        case httpStatus(Int)
        case invalidArchive

        var errorDescription: String? {
            switch self {
            case .noGitHubCLI: "L'outil GitHub (gh) est introuvable. Installez-le avec « brew install gh »."
            case .notLoggedIn: "Connectez-vous à GitHub avec « gh auth login » dans le Terminal."
            case .noRelease: "Aucune version n'a encore été publiée."
            case .httpStatus(let code): "GitHub a répondu \(code)."
            case .invalidArchive: "La version téléchargée est invalide."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks at most once a day, saying nothing unless an update is available.
    func checkAutomatically() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.automaticCheckKey, default: true) else { return }
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let token = try await Self.gitHubToken()
                let release = try await Self.latestRelease(token: token)
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if Self.isVersion(release.version, newerThan: Self.currentVersion) {
                    if offer(release) {
                        try await install(release, token: token)
                    }
                } else if userInitiated {
                    inform("Remote est à jour", "La version \(Self.currentVersion) est la plus récente.")
                }
            } catch {
                if userInitiated {
                    inform("Impossible de rechercher les mises à jour", error.localizedDescription)
                } else {
                    NSSound.beep()
                    RemoteModel.shared.showToast(error.localizedDescription)
                }
            }
        }
    }

    // MARK: GitHub

    private static func gitHubToken() async throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let gh = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw UpdateError.noGitHubCLI
        }
        guard let token = try? await run(gh, ["auth", "token", "--hostname", "github.com"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw UpdateError.notLoggedIn
        }
        return token
    }

    private static func latestRelease(token: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noRelease }
        guard status == 200 else { throw UpdateError.httpStatus(status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    static func isVersion(_ version: String, newerThan current: String) -> Bool {
        let parts = { (string: String) in string.split(separator: ".").map { Int($0) ?? 0 } }
        let (new, old) = (parts(version), parts(current))
        for index in 0..<max(new.count, old.count) {
            let (a, b) = (index < new.count ? new[index] : 0, index < old.count ? old[index] : 0)
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Installation

    private func offer(_ release: Release) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Remote \(release.version) est disponible"
        var details = "Vous avez la version \(Self.currentVersion)."
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            details += "\n\n" + String(notes.prefix(800))
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Installer et relancer")
        alert.addButton(withTitle: "Plus tard")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func install(_ release: Release, token: String) async throws {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else { throw UpdateError.invalidArchive }
        RemoteModel.shared.showToast("Téléchargement de Remote \(release.version)…")

        var request = URLRequest(url: asset.url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (download, response) = try await URLSession.shared.download(for: request, delegate: StorageRedirectDelegate())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.httpStatus(status) }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("Remote.zip")
        try FileManager.default.moveItem(at: download, to: archive)
        _ = try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])

        let newApp = folder.appendingPathComponent("Remote.app")
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              (try? await Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])) != nil else {
            throw UpdateError.invalidArchive
        }
        relaunch(replacingWith: newApp)
    }

    /// Replaces the app once it has quit, then opens the new version.
    private func relaunch(replacingWith newApp: URL) {
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$1.new" && /usr/bin/ditto "$2" "$1.new" && /bin/rm -rf "$1" && /bin/mv "$1.new" "$1"
        /usr/bin/open "$1"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", Bundle.main.bundleURL.path, newApp.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            inform("Impossible d'installer la mise à jour", error.localizedDescription)
        }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    continuation.resume(throwing: UpdateError.invalidArchive)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// GitHub answers asset downloads with a redirect to its file storage, which rejects
/// requests that still carry the GitHub token.
private final class StorageRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var request = request
        if request.url?.host != task.originalRequest?.url?.host {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
