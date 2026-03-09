import AppKit
import SwiftUI

struct WorkshopManagerView: View {
    @ObservedObject var steamManager: SteamCMDManager
    @EnvironmentObject private var extractor: PackageExtractor
    @Environment(\.dismiss) private var dismiss
    @State private var items: [WorkshopItem] = []
    @State private var search: String = ""
    @State private var sortMode: SortMode = .downloadNewest

    enum SortMode: String, CaseIterable, Identifiable {
        case downloadNewest = "Download Date (Newest)"
        case downloadOldest = "Download Date (Oldest)"
        case titleAZ = "Title A–Z"
        case titleZA = "Title Z–A"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                Text("Workshop Items")
                    .font(.title2).bold()
                Spacer()
                Button("Close") { dismiss() }
            }

            HStack(spacing: 12) {
                TextField("Search title or tag", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Button("Refresh") { loadItems() }
            }

            if items.isEmpty {
                VStack(spacing: 8) {
                    Text("No workshop items found")
                        .foregroundColor(.secondary)
                    Text(
                        "Expected in: ~/Library/Application Support/Steam/steamapps/workshop/content/431960"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let filtered = applyFiltersAndSorting()
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16
                    ) {
                        ForEach(filtered) { item in
                            WorkshopItemCard(item: item, steamManager: steamManager)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding()
        .frame(width: 800, height: 520)
        .onAppear { loadItems() }
        .onReceive(NotificationCenter.default.publisher(for: .workshopItemsChanged)) { _ in
            loadItems()
        }
    }

    private func loadItems() {
        items = steamManager.scanDownloadedWorkshopItems()
    }

    private func applyFiltersAndSorting() -> [WorkshopItem] {
        var result = items
        if !search.isEmpty {
            result = result.filter { item in
                let title = item.metadata.title ?? ""
                let tags = (item.metadata.tags ?? []).joined(separator: ", ")
                return title.localizedCaseInsensitiveContains(search)
                    || tags.localizedCaseInsensitiveContains(search)
            }
        }
        switch sortMode {
        case .downloadNewest:
            result.sort { ($0.downloadDate ?? .distantPast) > ($1.downloadDate ?? .distantPast) }
        case .downloadOldest:
            result.sort { ($0.downloadDate ?? .distantPast) < ($1.downloadDate ?? .distantPast) }
        case .titleAZ:
            result.sort {
                ($0.metadata.title ?? $0.folderURL.lastPathComponent)
                    .localizedCaseInsensitiveCompare(
                        $1.metadata.title ?? $1.folderURL.lastPathComponent) == .orderedAscending
            }
        case .titleZA:
            result.sort {
                ($0.metadata.title ?? $0.folderURL.lastPathComponent)
                    .localizedCaseInsensitiveCompare(
                        $1.metadata.title ?? $1.folderURL.lastPathComponent) == .orderedDescending
            }
        }
        return result
    }
}

private struct WorkshopItemCard: View {
    let item: WorkshopItem
    @ObservedObject var steamManager: SteamCMDManager
    @EnvironmentObject private var extractor: PackageExtractor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete: Bool = false
    @State private var opening: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isAnimatedPreview, let url = item.previewURL {
                AnimatedImageView(url: url)
                    .frame(height: 140)
                    .clipped()
                    .cornerRadius(8)
                    .allowsHitTesting(false)
            } else if let img = item.previewImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 140)
                    .clipped()
                    .cornerRadius(8)
                    .allowsHitTesting(false)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 140)
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                }
                .allowsHitTesting(false)
            }

            Text(item.metadata.title ?? item.folderURL.lastPathComponent)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.tail)

            if let tags = item.metadata.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }
                }
                .frame(height: 24)
                .allowsHitTesting(false)
            }

            HStack {
                if let firstPKG = item.pkgFiles.first {
                    Button(opening ? "Opening…" : "Open") {
                        print("[WorkshopManager] Button clicked! opening=\(opening)")
                        guard !opening else {
                            print("[WorkshopManager] Already opening, ignoring click")
                            return
                        }
                        opening = true
                        print("[WorkshopManager] Set opening=true, PKG path: \(firstPKG.path)")
                        print(
                            "[WorkshopManager] PKG exists: \(FileManager.default.fileExists(atPath: firstPKG.path))"
                        )
                        Task {
                            print("[WorkshopManager] Task started")
                            do {
                                print("[WorkshopManager] Calling extractPackage...")
                                try await extractor.extractPackage(from: firstPKG)
                                print("[WorkshopManager] Successfully extracted package")
                                await MainActor.run {
                                    print("[WorkshopManager] Dismissing view")
                                    dismiss()
                                }
                            } catch {
                                print(
                                    "[WorkshopManager] Extraction failed: \(error.localizedDescription)"
                                )
                                await MainActor.run {
                                    opening = false
                                    errorMessage = error.localizedDescription
                                    showingError = true
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(opening)
                    .alert("Extraction Failed", isPresented: $showingError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(errorMessage ?? "Unknown error")
                    }
                } else {
                    Text("No .pkg found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Reveal") {
                    print("[WorkshopManager] Reveal button clicked for: \(item.folderURL.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
                }
                Button(role: .destructive) {
                    print(
                        "[WorkshopManager] Delete button clicked for: \(item.folderURL.lastPathComponent)"
                    )
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this workshop item (moves to Trash if possible)")
                .alert("Delete Workshop Item?", isPresented: $confirmingDelete) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        do {
                            print("[WorkshopManager] Deleting item: \(item.folderURL.path)")
                            try steamManager.deleteWorkshopItem(at: item.folderURL)
                            // Trigger a refresh by posting a notification or rely on parent refresh
                            NotificationCenter.default.post(
                                name: .workshopItemsChanged, object: nil)
                            print("[WorkshopManager] Successfully deleted item")
                        } catch {
                            print("[WorkshopManager] Delete failed: \(error.localizedDescription)")
                            NSSound.beep()
                        }
                    }
                } message: {
                    Text(
                        "This will remove the folder \(item.folderURL.lastPathComponent) and its contents."
                    )
                }
            }
            .contentShape(Rectangle())
            .zIndex(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

extension Notification.Name {
    static let workshopItemsChanged = Notification.Name("WorkshopItemsChanged")
}

// MARK: - AnimatedImageView for GIF playback
private struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if let image = NSImage(contentsOf: url) {
            nsView.image = image
        }
    }
}
