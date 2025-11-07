import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            // App Icon and Title
            Image(systemName: "photo.stack")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Wallpaper Extractor")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal)

            // Description
            VStack(alignment: .leading, spacing: 12) {
                Text("Download and extract Wallpaper Engine projects from Steam Workshop")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text("Features:")
                    .font(.headline)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 6) {
                    FeatureRow(icon: "photo", text: "Convert .tex textures to PNG")
                    FeatureRow(icon: "play.rectangle", text: "Extract MP4 videos")
                    FeatureRow(icon: "arrow.down.circle", text: "Download from Steam Workshop")
                    FeatureRow(icon: "folder", text: "Export entire packages")
                }
                .padding(.horizontal)
            }

            Divider()
                .padding(.horizontal)

            // Credits
            VStack(spacing: 8) {
                Text("Created by")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("TrinityHades", destination: URL(string: "https://github.com/TrinityHades")!)
                    .font(.body)

                Text("Inspired by")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("RePKG by notscuffed", destination: URL(string: "https://github.com/notscuffed/repkg")!)
                    .font(.body)
            }

            // Support Button
            VStack(spacing: 8) {
                Text("Support Development")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link(destination: URL(string: "https://buymeacoffee.com/trinityhades")!) {
                    HStack {
                        Image(systemName: "cup.and.saucer.fill")
                        Text("Buy me 1mb of Mac Ram")
                    }
                    .font(.body)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.yellow)
                    .foregroundColor(.black)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)


            // Close Button
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.bottom)
        }
        .frame(width: 450, height: 600)
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    AboutView()
}
