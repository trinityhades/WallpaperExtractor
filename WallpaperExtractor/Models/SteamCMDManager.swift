import Foundation
import AppKit
import Combine

@MainActor
class SteamCMDManager: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var username: String = ""
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: String = ""
    @Published var lastDownloadedPath: URL?
    @Published var configuredSteamCMDPath: URL? {
        didSet {
            if let url = configuredSteamCMDPath {
                UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
            objectWillChange.send()
        }
    }

    private static let defaultsKey = "steamcmd.path"

    private var defaultSteamCMDURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Steam")
            .appendingPathComponent("steamcmd")
    }

    private var secondaryDefaultSteamCMDURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Steam")
            .appendingPathComponent("steamcmd.sh")
    }

    private var steamCMDURL: URL {
        if let set = configuredSteamCMDPath { return set }
        // Prefer 'steamcmd', fallback to 'steamcmd.sh'
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultSteamCMDURL.path) { return defaultSteamCMDURL }
        if fm.fileExists(atPath: secondaryDefaultSteamCMDURL.path) { return secondaryDefaultSteamCMDURL }
        return defaultSteamCMDURL
    }

    private var steamDirectoryURL: URL { steamCMDURL.deletingLastPathComponent() }
    private let workshopAppID = "431960" // Wallpaper Engine

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.path) { configuredSteamCMDPath = url }
        }
        checkLoginStatus()
    }

    var isSteamCMDInstalled: Bool {
        let fm = FileManager.default
        if let set = configuredSteamCMDPath, fm.fileExists(atPath: set.path) { return true }
        if fm.fileExists(atPath: defaultSteamCMDURL.path) { return true }
        if fm.fileExists(atPath: secondaryDefaultSteamCMDURL.path) { return true }
        return false
    }

    // Expose the currently selected or detected path for UI display (show configured even if missing)
    var effectiveSteamCMDURL: URL? {
        if let set = configuredSteamCMDPath { return set }
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultSteamCMDURL.path) { return defaultSteamCMDURL }
        if fm.fileExists(atPath: secondaryDefaultSteamCMDURL.path) { return secondaryDefaultSteamCMDURL }
        return nil
    }

    func checkLoginStatus() {
        // Check if there's a saved login by looking for the loginusers.vdf file
        let steamPath = steamDirectoryURL.appendingPathComponent("steamapps").path
        if FileManager.default.fileExists(atPath: steamPath) {
            // Try to read config to see if logged in
            let configPath = steamDirectoryURL.appendingPathComponent("config/config.vdf").path
            if FileManager.default.fileExists(atPath: configPath) {
                isLoggedIn = true
            }
        }
    }

    func login(username: String, password: String) async throws {
        guard isSteamCMDInstalled else {
            throw SteamCMDError.notInstalled
        }

        self.username = username
        downloadProgress = "Logging in to Steam..."

        do { try prepareSteamCMD() } catch { throw error }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "cd '\(steamDirectoryURL.path)' && ./\(steamCMDURL.lastPathComponent) +login \(username) \(password) +quit"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read output on a background thread and update UI on main thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let outputHandle = pipe.fileHandleForReading
                var allOutput = ""

                while process.isRunning {
                    let data = outputHandle.availableData
                    if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                        allOutput += output
                        print("🔍 SteamCMD Output: \(output)") // Debug logging
                        
                        // Parse steamcmd output for meaningful status updates
                        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                        for line in lines {
                            print("📝 Processing line: \(line)") // Debug logging
                            Task { @MainActor in
                                if line.contains("Steam Guard mobile authenticator") || line.contains("two-factor") {
                                    self.downloadProgress = "🔐 Waiting for Steam Guard approval on your mobile device..."
                                } else if line.contains("Waiting for confirmation") {
                                    self.downloadProgress = "🔐 Waiting for Steam Guard confirmation..."
                                } else if line.contains("Waiting for client config") || line.contains("client config") {
                                    self.downloadProgress = "⏳ Loading Steam configuration..."
                                } else if line.contains("Waiting for user info") || line.contains("user info") {
                                    self.downloadProgress = "⏳ Retrieving user information..."
                                } else if line.contains("Logging in user") {
                                    self.downloadProgress = "🔄 Authenticating with Steam..."
                                } else if line.contains("Logged in OK") || line.contains("Success") {
                                    self.downloadProgress = "✅ Login successful!"
                                } else if line.contains("FAILED") || line.contains("Invalid Password") {
                                    self.downloadProgress = "❌ Login failed"
                                } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    // Show any non-empty line as progress
                                    self.downloadProgress = "🔄 \(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))"
                                }
                            }
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                // Read any remaining data
                let remainingData = outputHandle.readDataToEndOfFile()
                if !remainingData.isEmpty, let output = String(data: remainingData, encoding: .utf8) {
                    allOutput += output
                    print("🔍 Final SteamCMD Output: \(output)") // Debug logging
                }
                
                print("📊 Complete SteamCMD Output:\n\(allOutput)") // Debug logging

                process.waitUntilExit()
                continuation.resume()
            }
        }

        if process.terminationStatus == 0 {
            isLoggedIn = true
            downloadProgress = "✅ Successfully logged in!"
        } else {
            let data = try? pipe.fileHandleForReading.readToEnd()
            let output = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if output.contains("operation not permitted") {
                throw SteamCMDError.permissionDenied("Execution blocked. Try moving steamcmd to ~/Steam and running: chmod +x steamcmd && xattr -d com.apple.quarantine steamcmd")
            }
            throw SteamCMDError.loginFailed(output)
        }
    }

    func parseWorkshopURL(_ urlString: String) throws -> String {
        // Extract workshop item ID from URL like:
        // https://steamcommunity.com/sharedfiles/filedetails/?id=2360329512
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let idItem = queryItems.first(where: { $0.name == "id" }),
              let workshopID = idItem.value else {
            throw SteamCMDError.invalidURL
        }

        return workshopID
    }

    func downloadWorkshopItem(workshopID: String) async throws -> URL {
        guard isSteamCMDInstalled else {
            throw SteamCMDError.notInstalled
        }

        guard isLoggedIn else {
            throw SteamCMDError.notLoggedIn
        }

        isDownloading = true
        downloadProgress = "Downloading workshop item \(workshopID)..."

        defer {
            isDownloading = false
        }

        do { try prepareSteamCMD() } catch { throw error }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd = "cd '\(steamDirectoryURL.path)' && ./\(steamCMDURL.lastPathComponent) +login \(username) " +
                  "+workshop_download_item \(workshopAppID) \(workshopID) validate +quit"
        process.arguments = ["-c", cmd]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read output asynchronously
        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                Task { @MainActor in
                    self.downloadProgress = output.components(separatedBy: "\n").last ?? self.downloadProgress
                }
            }
        }

        try process.run()
        process.waitUntilExit()

        outputHandle.readabilityHandler = nil

        if process.terminationStatus == 0 {
            downloadProgress = "Download complete!"

            // The downloaded content is in ~/Library/Application Support/Steam/steamapps/workshop/content/431960/{workshopID}
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
            let downloadPath = "\(homeDirectory)/Library/Application Support/Steam/steamapps/workshop/content/\(workshopAppID)/\(workshopID)"
            let url = URL(fileURLWithPath: downloadPath)

            if FileManager.default.fileExists(atPath: downloadPath) {
                lastDownloadedPath = url
                return url
            } else {
                throw SteamCMDError.downloadFailed("Download completed but files not found at expected location")
            }
        } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.contains("operation not permitted") {
                throw SteamCMDError.permissionDenied("Execution blocked. Try moving steamcmd to ~/Steam and running: chmod +x steamcmd && xattr -d com.apple.quarantine steamcmd")
            }
            throw SteamCMDError.downloadFailed(output)
        }
    }

    func findPKGFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var pkgFiles: [URL] = []

        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "pkg" {
                pkgFiles.append(fileURL)
            }
        }

        return pkgFiles
    }

    func setSteamCMDPath(_ url: URL) {
        print("[SteamCMDManager] Setting steamcmd path -> \(url.path)")
        configuredSteamCMDPath = url
        // Try to make it usable right away
        try? prepareSteamCMD()
    }

    func resetSteamCMDPath() {
        print("[SteamCMDManager] Resetting steamcmd path to default detection")
        configuredSteamCMDPath = nil
    }

    private func prepareSteamCMD() throws {
        guard let url = effectiveSteamCMDURL ?? configuredSteamCMDPath else { return }
        let path = url.path
        // If the file isn't executable, try to chmod +x
        if !FileManager.default.isExecutableFile(atPath: path) {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", path]
            try chmod.run()
            chmod.waitUntilExit()
        }
        // Remove quarantine if present (Gatekeeper can block exec -> operation not permitted)
        let xattrList = Process()
        xattrList.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrList.arguments = ["-p", "com.apple.quarantine", path]
        let pipe = Pipe()
        xattrList.standardOutput = pipe
        xattrList.standardError = Pipe()
        try? xattrList.run()
        xattrList.waitUntilExit()
        if xattrList.terminationStatus == 0 { // attribute exists
            let xattrDel = Process()
            xattrDel.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrDel.arguments = ["-d", "com.apple.quarantine", path]
            try? xattrDel.run()
            xattrDel.waitUntilExit()
            if xattrDel.terminationStatus != 0 {
                throw SteamCMDError.permissionDenied("Unable to remove quarantine from steamcmd. Run: xattr -d com.apple.quarantine \"\(path)\"")
            }
        }

        // Warn if inside app container; execution may be restricted in some setups
        if path.contains("/Library/Containers/") {
            // Not a hard error, but caller may show this info if subsequent exec fails
            print("[SteamCMDManager] steamcmd is inside an app container: \(path)")
        }
    }

    func installSteamCMD(to installDir: URL? = nil) async throws -> URL {
        let baseDir = installDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Steam")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let archiveURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
        downloadProgress = "Downloading SteamCMD..."

        let (tmpFile, response) = try await URLSession.shared.download(from: archiveURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SteamCMDError.downloadFailed("Failed to download SteamCMD")
        }

        downloadProgress = "Installing SteamCMD..."
        // Extract archive into baseDir
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = baseDir
        tar.arguments = ["-xzf", tmpFile.path]
        try tar.run()
        tar.waitUntilExit()
        if tar.terminationStatus != 0 { throw SteamCMDError.downloadFailed("Extraction failed") }

        // Pick the installed executable: prefer 'steamcmd', fallback to 'steamcmd.sh'
        let fm = FileManager.default
        let exe = baseDir.appendingPathComponent("steamcmd")
        let sh = baseDir.appendingPathComponent("steamcmd.sh")
        let steamcmd = fm.fileExists(atPath: exe.path) ? exe : sh

        // Ensure executable bit
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", steamcmd.path]
        try? chmod.run()
        chmod.waitUntilExit()

        configuredSteamCMDPath = steamcmd
        return steamcmd
    }
}

enum SteamCMDError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case invalidURL
    case loginFailed(String)
    case downloadFailed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            let expected1 = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Steam/steamcmd").path
            let expected2 = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Steam/steamcmd.sh").path
            return "SteamCMD not found. Install it or choose an existing executable (expected at \(expected1) or \(expected2))."
        case .notLoggedIn:
            return "You must be logged in to download workshop items"
        case .invalidURL:
            return "Invalid Steam Workshop URL. Expected format: https://steamcommunity.com/sharedfiles/filedetails/?id=XXXXXXXXX"
        case .loginFailed(let message):
            return "Login failed: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .permissionDenied(let message):
            return "Permission issue: \(message)"
        }
    }
}
