struct WorkshopDownloadView: View {
    @EnvironmentObject var extractor: PackageExtractor
    @State private var extracting: Bool = false
    @State private var progress: Float = 0.0

    var body: some View {
        VStack {
            if extracting {
                ProgressView(value: progress)
                    .padding()
            } else {
                Button("Start Extraction") {
                    extracting = true
                    extractor.startExtraction { prog in
                        progress = prog
                        if prog >= 1.0 {
                            extracting = false
                        }
                    }
                }
            }
        }
    }
}
