import Foundation

public enum WallpaperType: String, Codable, Sendable {
    case video = "video"
    case scene = "scene"
    case web = "web"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .video: return "视频 (MP4)"
        case .scene: return "场景 (Scene)"
        case .web: return "网页 (Web)"
        case .unknown: return "未知"
        }
    }

    public var isPlayableVideo: Bool {
        return self == .video
    }
}

public struct WallpaperItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var type: WallpaperType
    public var videoURL: URL?
    public var previewURL: URL?
    public var audioURL: URL?
    public var htmlURL: URL?
    public var localDirectoryURL: URL
    public var fileSize: Int64
    public var tags: [String]
    public var addedAt: Date

    public init(
        id: String,
        title: String,
        type: WallpaperType,
        videoURL: URL? = nil,
        previewURL: URL? = nil,
        audioURL: URL? = nil,
        htmlURL: URL? = nil,
        localDirectoryURL: URL,
        fileSize: Int64 = 0,
        tags: [String] = [],
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.videoURL = videoURL
        self.previewURL = previewURL
        self.audioURL = audioURL
        self.htmlURL = htmlURL
        self.localDirectoryURL = localDirectoryURL
        self.fileSize = fileSize
        self.tags = tags
        self.addedAt = addedAt
    }

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

public struct WorkshopItemMetadata: Sendable, Codable {
    public let publishedfileid: String
    public let title: String
    public let previewURL: String?
    public let fileSize: Int64
    public let tags: [String]
    public let inferredType: WallpaperType

    public init(
        publishedfileid: String,
        title: String,
        previewURL: String?,
        fileSize: Int64,
        tags: [String],
        inferredType: WallpaperType
    ) {
        self.publishedfileid = publishedfileid
        self.title = title
        self.previewURL = previewURL
        self.fileSize = fileSize
        self.tags = tags
        self.inferredType = inferredType
    }
}

public enum DownloadState: Sendable, Equatable {
    case idle
    case parsing(id: String)
    case downloading(id: String, message: String)
    case unpacking(id: String)
    case completed(item: WallpaperItem)
    case failed(message: String)
}
