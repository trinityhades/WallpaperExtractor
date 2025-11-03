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

    private var steamCMDPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Steam/steamcmd.sh"
    }
    private var steamDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Steam"
    }
    private let workshopAppID = "431960" // Wallpaper Engine

    init() {
        checkLoginStatus()
    }

    var isSteamCMDInstalled: Bool {
        FileManager.default.fileExists(atPath: steamCMDPath)
    }

    func checkLoginStatus() {
        // Check if there's a saved login by looking for the loginusers.vdf file
        let steamPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Steam/steamapps"
        if FileManager.default.fileExists(atPath: steamPath) {
            // Try to read config to see if logged in
            let configPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Steam/config/config.vdf"
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "cd '\(steamDirectory)' && ./steamcmd.sh +login \(username) \(password) +quit"]

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd = "cd '\(steamDirectory)' && ./steamcmd.sh +login \(username) " +
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
}

enum SteamCMDError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case invalidURL
    case loginFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            let steamPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Steam/steamcmd.sh"
            return "SteamCMD is not installed at \(steamPath)"
        case .notLoggedIn:
            return "You must be logged in to download workshop items"
        case .invalidURL:
            return "Invalid Steam Workshop URL. Expected format: https://steamcommunity.com/sharedfiles/filedetails/?id=XXXXXXXXX"
        case .loginFailed(let message):
            return "Login failed: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        }
    }
}
