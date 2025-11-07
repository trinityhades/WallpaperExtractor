//
//  WallpaperExtractorApp.swift
//  WallpaperExtractor
//
//  Created by TrinityHades on 11/2/25.
//

import SwiftUI

@main
struct WallpaperExtractorApp: App {
    @StateObject private var extractor = PackageExtractor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(extractor)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    Task {
                        try? await extractor.extractPackage(from: url)
                    }
                }
        }
    }
}
