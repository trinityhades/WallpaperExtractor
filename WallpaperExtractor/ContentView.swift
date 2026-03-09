import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var extractor: PackageExtractor
    @StateObject private var steamManager = SteamCMDManager()
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingExportPanel = false
    @State private var showingWorkshopSheet = false
    @State private var showingWorkshopManager = false
    @State private var showingAbout = false

    @State private var selectedNode: FileNode?

    var body: some View {
        HSplitView {
            // Sidebar: package contents tree
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: { openPKGPicker() }) {
                        Label("Open PKG…", systemImage: "folder")
                    }
                    .keyboardShortcut("o")

                    Button(action: { showingWorkshopSheet = true }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    Button(action: { showingWorkshopManager = true }) {
                        Label("Workshop", systemImage: "rectangle.grid.2x2")
                    }

                    Button(action: { showingExportPanel = true }) {
                        Label("Export…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!extractor.canExport)

                    Button(action: { showingAbout = true }) {
                        Label("About", systemImage: "info.circle")
                    }

                }
                .padding(8)
                Divider()
                ScrollView {
                    if extractor.fileTree.isEmpty {
                        Text("No package loaded")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(extractor.fileTree) { root in
                                FileTreeView(node: root, selectedPath: $selectedNode, depth: 0)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(minWidth: 580, idealWidth: 620)
            .layoutPriority(1)

            // Detail: preview and file info
            VStack(alignment: .leading) {
                if extractor.isExtracting {
                    HStack(spacing: 12) {
                        ProgressView(value: extractor.extractionProgress)
                            .frame(width: 200)
                        Text(extractor.extractionMessage)
                            .foregroundColor(.secondary)
                    }
                    .padding([.top, .horizontal])
                }
                if let node = selectedNode {
                    HStack {
                        Text(node.path)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)
                    }
                    .padding([.top, .horizontal])
                    Divider()
                    if !node.isDirectory {
                        PackageFilePreview(path: node.path)
                            .environmentObject(extractor)
                    } else {
                        Text("Folder contains \(node.children.count) item(s)")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                    Spacer()
                } else {
                    VStack(spacing: 12) {
                        Text("Select a file or folder on the left")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingWorkshopSheet) {
            WorkshopDownloadView(steamManager: steamManager) { error in
                if let error = error {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
            .environmentObject(extractor)
        }
        .sheet(isPresented: $showingWorkshopManager) {
            WorkshopManagerView(steamManager: steamManager)
                .environmentObject(extractor)
        }
        .sheet(isPresented: $showingExportPanel) {
            ExportOptionsSheet { destination, options in
                do {
                    try extractor.export(to: destination, options: options)
                    NSWorkspace.shared.open(destination)
                } catch {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
            .environmentObject(extractor)
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .alert("Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func openPKGPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .data]
        panel.prompt = "Open"

        // Default directory: Steam Workshop downloads for Wallpaper Engine (431960)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base =
            home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Steam")
            .appendingPathComponent("steamapps")
            .appendingPathComponent("workshop")
            .appendingPathComponent("content")
            .appendingPathComponent("431960")
        if FileManager.default.fileExists(atPath: base.path) {
            panel.directoryURL = base
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await extractor.extractPackage(from: url)
                } catch {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        }
    }

    private func exportAll() {}
}

private struct PackageFilePreview: View {
    let path: String
    @EnvironmentObject private var extractor: PackageExtractor
    @State private var previewContent: PackageExtractor.PreviewContent = .unsupported

    var body: some View {
        Group {
            switch previewContent {
            case .image(let image):
                ScrollView {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            case .video(let url):
                VideoPreview(url: url)
                    .padding()
            case .unsupported:
                Text("No preview available")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task(id: path) {
            previewContent = extractor.previewContent(for: path)
        }
    }
}

private struct VideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: url) {
            let newPlayer = AVPlayer(url: url)
            newPlayer.pause()
            player = newPlayer
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private func byteCount(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

extension FileNode {
    fileprivate var childrenOptional: [FileNode]? {
        children.isEmpty ? nil : children
    }
}

// Sheet view for selecting export destination and options
private struct ExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var extractor: PackageExtractor
    @State private var destinationURL: URL? = BookmarkStore.resolve(
        forKey: "exportDestinationBookmark")
    @AppStorage("exportIncludeImages") private var includeImages: Bool = true
    @AppStorage("exportIncludeVideos") private var includeVideos: Bool = true
    @AppStorage("exportIncludeOther") private var includeOther: Bool = true
    @AppStorage("exportFlattenFolders") private var flattenFolders: Bool = false
    @AppStorage("exportTrinityPreferred") private var trinityPreferred: Bool = false
    @AppStorage("exportMipmaps") private var exportMipmaps: Bool = false
    @AppStorage("exportNonPremultiplied") private var nonPremultipliedAlpha: Bool = false
    @AppStorage("exportLinearColorSpace") private var useLinearColorSpace: Bool = false
    @State private var showingFolderPicker: Bool = false
    let onExport: (URL, PackageExtractor.ExportOptions) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
                Text("Export Options")
                    .font(.title2).bold()
            }

            Text(
                "Choose what to export from the loaded package (\(extractor.entriesCount) entries)."
            )
            .foregroundColor(.secondary)

            // Scrollable content to avoid clipping in small sheets
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox(label: Text("Destination")) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let dest = destinationURL {
                                Text(dest.path)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            } else {
                                Text("No folder selected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Button("Choose Folder…") { pickFolder() }
                                if let dest = destinationURL {
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox(label: Text("Content Types")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Images (PNG/JPG/TEX->PNG)", isOn: $includeImages)
                            Toggle("Videos (MP4)", isOn: $includeVideos)
                            Toggle("Other Files (raw)", isOn: $includeOther)
                        }
                    }

                    GroupBox(label: Text("Structure")) {
                        Toggle("Flatten folder structure (no subfolders)", isOn: $flattenFolders)
                    }

                    GroupBox(label: Text("Presets")) {
                        Toggle("Trinity's Preferred", isOn: $trinityPreferred)
                            .help(
                                "Images under 'materials' -> Main Images; consolidate effects/masks/models/xray into top-level folders while preserving deeper subpaths."
                            )
                    }

                    GroupBox(label: Text("Advanced")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Export mipmaps (all levels)", isOn: $exportMipmaps)
                            Toggle("Non-premultiplied alpha", isOn: $nonPremultipliedAlpha)
                            Toggle("Linear sRGB color space", isOn: $useLinearColorSpace)
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Button row pinned after scrollable content
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Reset Defaults") {
                    destinationURL = nil
                    BookmarkStore.remove(forKey: "exportDestinationBookmark")
                    includeImages = true
                    includeVideos = true
                    includeOther = true
                    flattenFolders = false
                    trinityPreferred = false
                }
                .help("Clear saved destination and restore initial toggle values")
                Button("Export") {
                    guard let dest = destinationURL else { return }
                    let opts = PackageExtractor.ExportOptions(
                        includeImages: includeImages,
                        includeVideos: includeVideos,
                        includeOther: includeOther,
                        flattenFolders: flattenFolders,
                        trinityPreferred: trinityPreferred,
                        exportMipmaps: exportMipmaps,
                        nonPremultipliedAlpha: nonPremultipliedAlpha,
                        useLinearColorSpace: useLinearColorSpace
                    )
                    onExport(dest, opts)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    destinationURL == nil || (!includeImages && !includeVideos && !includeOther))
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK { destinationURL = panel.url }
            if let url = destinationURL {
                BookmarkStore.save(url: url, forKey: "exportDestinationBookmark")
            }
        }
    }
}

private struct FileTreeView: View {
    let node: FileNode
    @Binding var selectedPath: FileNode?
    let depth: Int
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileRow(node: node, selectedPath: $selectedPath, depth: depth, isExpanded: $isExpanded)
                .onTapGesture {
                    if node.isDirectory {
                        isExpanded.toggle()
                    }
                    selectedPath = node
                }

            if isExpanded && !node.children.isEmpty {
                ForEach(node.children) { child in
                    FileTreeView(node: child, selectedPath: $selectedPath, depth: depth + 1)
                }
            }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    @Binding var selectedPath: FileNode?
    let depth: Int
    @Binding var isExpanded: Bool
    @EnvironmentObject private var extractor: PackageExtractor

    var body: some View {
        HStack(spacing: 8) {
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            } else {
                Spacer()
                    .frame(width: 12)
            }

            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundColor(node.isDirectory ? .accentColor : .secondary)
            Text(node.name)
            Spacer()
            if !node.isDirectory {
                Text(byteCount(node.size))
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(depth * 16))
        .background((selectedPath?.id == node.id) ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .onDrag {
            guard !node.isDirectory else { return NSItemProvider() }
            if let url = try? extractor.temporaryRawFileURL(for: node.path) {
                if let provider = NSItemProvider(contentsOf: url) { return provider }
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        }
    }
}

struct ImageCard: View {
    let image: NSImage
    let name: String

    var body: some View {
        VStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 150)
                .cornerRadius(8)

            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Copy Image") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            }
            Button("Save Image...") {
                saveImage(image, name: name)
            }
        }
    }

    private func saveImage(_ image: NSImage, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: ".tex", with: ".png")
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let tiffData = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiffData),
                    let pngData = bitmap.representation(using: .png, properties: [:])
                {
                    try? pngData.write(to: url)
                }
            }
        }
    }
}

struct ExtractedImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let name: String
}

struct WorkshopDownloadView: View {
    @ObservedObject var steamManager: SteamCMDManager
    let onError: (Error?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var extractor: PackageExtractor
    @State private var workshopURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var steamGuardCode: String = ""
    @State private var isProcessing: Bool = false
    @State private var rememberMe: Bool = true
    @State private var foundPKGFiles: [URL] = []
    @State private var showingPKGPicker: Bool = false
    @State private var showingSteamCMDPicker: Bool = false
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                Text("Steam Workshop Downloader")
                    .font(.title)
            }
            .padding(.top)

            // SteamCMD quick settings row (always available)
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundColor(.secondary)
                Text("SteamCMD:")
                    .foregroundColor(.secondary)
                Text(steamManager.effectiveSteamCMDURL?.path ?? "Not found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let eff = steamManager.effectiveSteamCMDURL {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([eff]) }
                }
                Button("Change…") { showingSteamCMDPicker = true }
                Button("Reset") {
                    steamManager.resetSteamCMDPath()
                }
            }
            .padding(.horizontal)

            if !steamManager.isSteamCMDInstalled {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    Text("SteamCMD Not Found")
                        .font(.headline)
                    Text("Install SteamCMD or choose an existing steamcmd executable")
                        .foregroundColor(.secondary)
                    Text(
                        "Expected at: \(FileManager.default.homeDirectoryForCurrentUser.path)/Steam/steamcmd or steamcmd.sh"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Button("Install SteamCMD") {
                            Task {
                                do {
                                    _ = try await steamManager.installSteamCMD()
                                } catch {
                                    onError(error)
                                }
                            }
                        }
                        Button("Choose steamcmd…") { showingSteamCMDPicker = true }
                    }
                    Button("Install Instructions") {
                        NSWorkspace.shared.open(
                            URL(string: "https://developer.valvesoftware.com/wiki/SteamCMD")!)
                    }
                }
                .padding()
            } else if !steamManager.isLoggedIn {
                // Login form
                VStack(alignment: .leading, spacing: 16) {
                    Text("Login to Steam")
                        .font(.headline)

                    Text(
                        "After first successful login with Steam Guard, this Mac will be remembered and won't require codes for future logins."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if let error = loginError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }

                    if !isProcessing {
                        // Input fields
                        TextField("Steam Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                            .autocorrectionDisabled(true)
                            .privacySensitive()

                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .privacySensitive()

                        TextField("Steam Guard Code (optional)", text: $steamGuardCode)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.oneTimeCode)
                            .autocorrectionDisabled(true)
                            .privacySensitive()
                            .onSubmit { submitLogin() }

                        // Action row
                        HStack {
                            Button("Cancel") { dismiss() }
                            Spacer()
                            Toggle("Remember Me", isOn: $rememberMe)
                                .toggleStyle(.checkbox)
                                .help("Stores credentials securely in Keychain on successful login")
                            Button("Login") { submitLogin() }
                                .buttonStyle(.borderedProminent)
                                .disabled(username.isEmpty || password.isEmpty)
                        }
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .padding()

                            Text(steamManager.downloadProgress)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.primary)
                                .padding(.horizontal)

                            if steamManager.downloadProgress.contains("Steam Guard") {
                                Text(
                                    "Check your Steam Mobile app or enter the email / one‑time code above."
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
                .onAppear { prefillCredentials() }
                .padding()
                .frame(width: 450)
            } else if showingPKGPicker {
                // PKG file picker (multiple PKG files found in workshop item)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Found \(foundPKGFiles.count) PKG file(s)")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(foundPKGFiles, id: \.self) { pkgURL in
                                HStack {
                                    Image(systemName: "doc.zipper")
                                        .foregroundColor(.blue)
                                    Text(pkgURL.lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("Extract") {
                                        Task {
                                            do {
                                                try await extractor.extractPackage(from: pkgURL)
                                                dismiss()
                                            } catch {
                                                onError(error)
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    HStack {
                        Button("Close") { showingPKGPicker = false }
                        Spacer()
                    }
                }
                .padding()
                .frame(width: 500)
            } else {
                // Workshop URL input
                VStack(alignment: .leading, spacing: 16) {
                    Text("Logged in as: \(steamManager.username)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Enter Workshop URL")
                        .font(.headline)

                    TextField(
                        "https://steamcommunity.com/sharedfiles/filedetails/?id=...",
                        text: $workshopURL
                    )
                    .textFieldStyle(.roundedBorder)

                    if isProcessing {
                        ProgressView()
                        Text(steamManager.downloadProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }

                        Spacer()

                        Button("Download & Extract") {
                            Task {
                                isProcessing = true
                                do {
                                    let workshopID = try steamManager.parseWorkshopURL(workshopURL)
                                    let downloadPath = try await steamManager.downloadWorkshopItem(
                                        workshopID: workshopID)

                                    // Find PKG files in the downloaded directory
                                    foundPKGFiles = try steamManager.findPKGFiles(in: downloadPath)

                                    if foundPKGFiles.isEmpty {
                                        throw SteamCMDError.downloadFailed(
                                            "No .pkg files found in the downloaded workshop item")
                                    } else if foundPKGFiles.count == 1 {
                                        // Auto-extract if only one PKG file
                                        try await extractor.extractPackage(from: foundPKGFiles[0])
                                        dismiss()
                                    } else {
                                        // Show picker if multiple PKG files
                                        showingPKGPicker = true
                                    }
                                } catch {
                                    onError(error)
                                    dismiss()
                                }
                                isProcessing = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workshopURL.isEmpty || isProcessing)
                    }
                }
                .padding()
                .frame(width: 500)
            }

            Spacer()
        }
        .frame(minWidth: 500, minHeight: 400)
        .fileImporter(
            isPresented: $showingSteamCMDPicker, allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                print("[WorkshopDownloadView] Picked steamcmd path -> \(url.path)")
                steamManager.setSteamCMDPath(url)
            case .failure(let error):
                onError(error)
            }
        }
    }
}

// MARK: - WorkshopDownloadView Helpers
extension WorkshopDownloadView {
    fileprivate func submitLogin() {
        guard !username.isEmpty, !password.isEmpty, !isProcessing else { return }
        loginError = nil
        isProcessing = true
        let code = steamGuardCode.isEmpty ? nil : steamGuardCode
        Task {
            do {
                try await steamManager.login(
                    username: username, password: password, steamGuardCode: code)
                if rememberMe {
                    try? Keychain.saveString(
                        service: "WallpaperExtractor", account: "steam.username", value: username)
                    try? Keychain.saveString(
                        service: "WallpaperExtractor", account: "steam.password", value: password)
                }
            } catch {
                await MainActor.run { loginError = error.localizedDescription }
            }
            await MainActor.run { isProcessing = false }
        }
    }

    fileprivate func prefillCredentials() {
        if let savedUser = Keychain.loadString(
            service: "WallpaperExtractor", account: "steam.username")
        {
            username = savedUser
        }
        if let savedPass = Keychain.loadString(
            service: "WallpaperExtractor", account: "steam.password")
        {
            password = savedPass
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PackageExtractor())
}
