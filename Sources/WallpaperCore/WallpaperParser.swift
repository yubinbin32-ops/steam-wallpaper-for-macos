import Foundation

public struct WallpaperParser: Sendable {
    public static let shared = WallpaperParser()

    public init() {}

    /// Parses a single workshop item directory
    public func parseDirectory(at directoryURL: URL) throws -> WallpaperItem {
        let projectJsonURL = directoryURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: projectJsonURL.path) else {
            throw NSError(
                domain: "WallpaperParser",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到 project.json: \(directoryURL.path)"]
            )
        }

        let data = try Data(contentsOf: projectJsonURL)

        struct RawProject: Decodable {
            let title: String?
            let type: String?
            let file: String?
            let preview: String?
            let tags: [String]?
            let workshopid: String?
        }

        let rawProject = try JSONDecoder().decode(RawProject.self, from: data)
        let id = rawProject.workshopid ?? directoryURL.lastPathComponent
        let title = rawProject.title ?? "未命名壁纸 (\(id))"
        let rawType = (rawProject.type ?? "unknown").lowercased()

        var type: WallpaperType = .unknown
        if rawType == "video" {
            type = .video
        } else if rawType == "scene" {
            type = .scene
        } else if rawType == "web" {
            type = .web
        }

        // Preview Image
        var previewURL: URL?
        if let previewName = rawProject.preview {
            let candidate = directoryURL.appendingPathComponent(previewName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                previewURL = candidate
            }
        }
        if previewURL == nil {
            for ext in ["jpg", "jpeg", "png"] {
                let candidate = directoryURL.appendingPathComponent("preview.\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    previewURL = candidate
                    break
                }
            }
        }

        // Video File
        var videoURL: URL?
        if type == .video {
            if let fileName = rawProject.file {
                let candidate = directoryURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    videoURL = candidate
                }
            }
            if videoURL == nil {
                // Scan directory for video files
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
                let videoExtensions = ["mp4", "webm", "mov", "m4v", "mkv"]
                for file in files {
                    let ext = (file as NSString).pathExtension.lowercased()
                    if videoExtensions.contains(ext) {
                        videoURL = directoryURL.appendingPathComponent(file)
                        break
                    }
                }
            }
        }

        // Scene high-res artwork & audio extraction
        var audioURL: URL?
        let scenePkgURL = directoryURL.appendingPathComponent("scene.pkg")
        let artworkURL = directoryURL.appendingPathComponent("artwork.png")

        if FileManager.default.fileExists(atPath: artworkURL.path) {
            previewURL = artworkURL
        } else if type == .scene && FileManager.default.fileExists(atPath: scenePkgURL.path) {
            if let extractedArtwork = try? extractArtworkFromPkg(at: scenePkgURL, targetDirectory: directoryURL) {
                previewURL = extractedArtwork
            }
        }

        if type == .scene {
            // Check if audio file already exists in directory
            let audioExts = ["flac", "mp3", "ogg", "wav"]
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                if audioExts.contains(ext) {
                    audioURL = directoryURL.appendingPathComponent(file)
                    break
                }
            }

            if audioURL == nil && FileManager.default.fileExists(atPath: scenePkgURL.path) {
                audioURL = try? extractFirstAudioFromPkg(at: scenePkgURL, targetDirectory: directoryURL)
            }
        }

        // Calculate size
        let totalSize = directorySize(url: directoryURL)

        return WallpaperItem(
            id: id,
            title: title,
            type: type,
            videoURL: videoURL,
            previewURL: previewURL,
            audioURL: audioURL,
            localDirectoryURL: directoryURL,
            fileSize: totalSize,
            tags: rawProject.tags ?? []
        )
    }

    /// Scans the Steam Workshop directory and parses all installed wallpapers
    public func scanWorkshopDirectory(at directoryURL: URL) -> [WallpaperItem] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }

        var items: [WallpaperItem] = []
        let contents = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        for subfolder in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: subfolder.path, isDirectory: &isDir), isDir.boolValue {
                if let item = try? parseDirectory(at: subfolder) {
                    items.append(item)
                }
            }
        }

        return items.sorted(by: { $0.title < $1.title })
    }

    // MARK: - Internal Binary PKG Unpacker (PKGV0023)

    /// Extracts the first audio file found inside a scene.pkg for music preview
    private func extractFirstAudioFromPkg(at pkgURL: URL, targetDirectory: URL) throws -> URL? {
        let handle = try FileHandle(forReadingFrom: pkgURL)
        defer { try? handle.close() }

        // Read magic length (4 bytes UInt32)
        guard let magicLenData = try? handle.read(upToCount: 4), magicLenData.count == 4 else { return nil }
        let magicLen = magicLenData.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Read magic
        guard let magicData = try? handle.read(upToCount: Int(magicLen)),
              let magic = String(data: magicData, encoding: .ascii),
              magic.hasPrefix("PKGV") else { return nil }

        // Read file count (4 bytes UInt32)
        guard let countData = try? handle.read(upToCount: 4), countData.count == 4 else { return nil }
        let fileCount = countData.withUnsafeBytes { $0.load(as: UInt32.self) }

        struct Entry {
            let name: String
            let offset: UInt32
            let size: UInt32
        }

        var entries: [Entry] = []
        for _ in 0..<fileCount {
            guard let nameLenData = try? handle.read(upToCount: 4), nameLenData.count == 4 else { break }
            let nameLen = nameLenData.withUnsafeBytes { $0.load(as: UInt32.self) }

            guard let nameData = try? handle.read(upToCount: Int(nameLen)),
                  let name = String(data: nameData, encoding: .utf8) else { break }

            guard let offsetData = try? handle.read(upToCount: 4), offsetData.count == 4 else { break }
            let offset = offsetData.withUnsafeBytes { $0.load(as: UInt32.self) }

            guard let sizeData = try? handle.read(upToCount: 4), sizeData.count == 4 else { break }
            let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self) }

            entries.append(Entry(name: name, offset: offset, size: size))
        }

        let headerEndOffset = try handle.offset()

        let audioExtensions = [".flac", ".mp3", ".ogg", ".wav"]
        let audioEntries = entries
            .filter { entry in
                let lower = entry.name.lowercased()
                return audioExtensions.contains(where: { lower.hasSuffix($0) })
            }
            .sorted(by: { $0.size > $1.size }) // Prefer full soundtrack over short sound effects

        for entry in audioEntries {
            try handle.seek(toOffset: headerEndOffset + UInt64(entry.offset))
            guard let audioData = try handle.read(upToCount: Int(entry.size)) else { continue }

            var cleanBaseName = (entry.name as NSString).lastPathComponent
            while cleanBaseName.hasPrefix(".") {
                cleanBaseName.removeFirst()
            }
            if cleanBaseName.isEmpty {
                cleanBaseName = "audio.flac"
            }

            let outputURL = targetDirectory.appendingPathComponent(cleanBaseName)
            try audioData.write(to: outputURL)
            return outputURL
        }

        return nil
    }

    /// Extracts embedded high-resolution artwork from scene.pkg
    private func extractArtworkFromPkg(at pkgURL: URL, targetDirectory: URL) throws -> URL? {
        guard let data = try? Data(contentsOf: pkgURL) else { return nil }
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if let range = data.range(of: pngHeader) {
            let pngData = data.subdata(in: range.lowerBound..<data.count)
            let outputURL = targetDirectory.appendingPathComponent("artwork.png")
            try pngData.write(to: outputURL)
            return outputURL
        }
        return nil
    }

    private func directorySize(url: URL) -> Int64 {
        var size: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        return size
    }
}
