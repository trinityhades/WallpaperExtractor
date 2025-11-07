import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var extractor: PackageExtractor
    @StateObject private var steamManager = SteamCMDManager()
    @State private var isImporting = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingExportPanel = false
    @State private var showingWorkshopSheet = false
    @State private var showingAbout = false

    @State private var selectedNode: FileNode?

    var body: some View {
        HSplitView {
            // Sidebar: package contents tree
            VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(action: { isImporting = true }) {
                            Label("Open PKG…", systemImage: "folder")
                        }
                        .keyboardShortcut("o")

                        Button(action: { showingWorkshopSheet = true }) {
                            Label("Workshop", systemImage: "arrow.down.circle")
                        }


                        Button(action: { exportAll() }) {
                            Label("Export All…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!extractor.canExport)
                        
                        Button(action: { showingAbout = true }) {
                            Label("About", systemImage: "info.circle")
                        }
                        
                    }
                    .padding(8)
                    Divider()
                    if extractor.fileTree.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.zipper")
                                .font(.system(size: 60))
                                .foregroundColor(.blue)
                            Text("Open a .pkg to view its contents")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(extractor.fileTree) { node in
                                    FileTreeView(node: node, selectedPath: $selectedNode, depth: 0)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                .frame(minWidth: 440)

                // Detail: preview and file info
                VStack(alignment: .leading) {
                    if let node = selectedNode {
                        HStack {
                            Text(node.path)
                                .font(.headline)
                            Spacer()
                            Text(node.isDirectory ? "Folder" : byteCount(node.size))
                                .foregroundColor(.secondary)
                        }
                        .padding([.top, .horizontal])
                        Divider()
                        if !node.isDirectory {
                            if let img = extractor.previewImage(for: node.path) {
                                ScrollView {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .padding()
                                }
                            } else {
                                Text("No preview available")
                                    .foregroundColor(.secondary)
                                    .padding()
                            }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "pkg") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .sheet(isPresented: $showingWorkshopSheet) {
            WorkshopDownloadView(steamManager: steamManager) { error in
                if let error = error {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    try await extractor.extractPackage(from: url)
                } catch {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let folder = panel.url {
                do {
                    try extractor.exportAll(to: folder)
                    NSWorkspace.shared.open(folder)
                } catch {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        }
    }
}

private func byteCount(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

private extension FileNode {
    var childrenOptional: [FileNode]? {
        children.isEmpty ? nil : children
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
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
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
    @State private var isProcessing: Bool = false
    @State private var foundPKGFiles: [URL] = []
    @State private var showingPKGPicker: Bool = false
    @State private var showingSteamCMDPicker: Bool = false

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
                Text(steamManager.configuredSteamCMDPath?.path ?? "Not set")
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
                    Text("Expected at: \(FileManager.default.homeDirectoryForCurrentUser.path)/Steam/steamcmd or steamcmd.sh")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Button("Install SteamCMD") {
                            Task {
                                do {
                                    try await steamManager.installSteamCMD()
                                } catch {
                                    onError(error)
                                }
                            }
                        }
                        Button("Choose steamcmd…") { showingSteamCMDPicker = true }
                    }
                    Button("Install Instructions") {
                        NSWorkspace.shared.open(URL(string: "https://developer.valvesoftware.com/wiki/SteamCMD")!)
                    }
                }
                .padding()
            } else if !steamManager.isLoggedIn {
                // Login form
                VStack(alignment: .leading, spacing: 16) {
                    Text("Login to Steam")
                        .font(.headline)

                    if !isProcessing {
                        TextField("Steam Username", text: $username)
                            .textFieldStyle(.roundedBorder)

                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !username.isEmpty && !password.isEmpty {
                                    Task {
                                        isProcessing = true
                                        do {
                                            try await steamManager.login(username: username, password: password)
                                        } catch {
                                            onError(error)
                                            dismiss()
                                        }
                                        isProcessing = false
                                    }
                                }
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
                                Text("Check your Steam Mobile app")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }

                        Spacer()

                        if !isProcessing {
                            Button("Login") {
                                Task {
                                    isProcessing = true
                                    do {
                                        try await steamManager.login(username: username, password: password)
                                    } catch {
                                        onError(error)
                                        dismiss()
                                    }
                                    isProcessing = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(username.isEmpty || password.isEmpty)
                        }
                    }
                }
                .padding()
                .frame(width: 450)
            } else if showingPKGPicker {
                // PKG file picker
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
                        Button("Close") {
                            dismiss()
                        }
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

                    TextField("https://steamcommunity.com/sharedfiles/filedetails/?id=...", text: $workshopURL)
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
                                    let downloadPath = try await steamManager.downloadWorkshopItem(workshopID: workshopID)

                                    // Find PKG files in the downloaded directory
                                    foundPKGFiles = try steamManager.findPKGFiles(in: downloadPath)

                                    if foundPKGFiles.isEmpty {
                                        throw SteamCMDError.downloadFailed("No .pkg files found in the downloaded workshop item")
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
        .fileImporter(isPresented: $showingSteamCMDPicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
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

#Preview {
    ContentView()
        .environmentObject(PackageExtractor())
}
