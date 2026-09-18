import Foundation

public struct SteamWorkshopService: Sendable {
    public static let shared = SteamWorkshopService()

    public init() {}

    /// Extracts the Steam PublishedFileId from a user input string (URL, URI, or raw numeric ID)
    public func extractWorkshopId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy({ $0.isNumber }) && !trimmed.isEmpty {
            return trimmed
        }

        // Try parsing URL query parameter ?id=...
        if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let queryItems = components.queryItems,
               let idItem = queryItems.first(where: { $0.name.lowercased() == "id" }),
               let value = idItem.value,
               value.allSatisfy({ $0.isNumber }), !value.isEmpty {
                return value
            }
            // Check path like /.../123456
            let lastComponent = url.lastPathComponent
            if lastComponent.allSatisfy({ $0.isNumber }) && !lastComponent.isEmpty {
                return lastComponent
            }
        }

        // Regex fallback: find pattern (?<=id=)[0-9]+ or (\d{8,})
        if let regex = try? NSRegularExpression(pattern: #"(?:id=|\/)(\d{6,})"#) {
            let nsString = trimmed as NSString
            let results = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsString.length))
            if let first = results.first, first.numberOfRanges > 1 {
                let range = first.range(at: 1)
                return nsString.substring(with: range)
            }
        }

        return nil
    }

    /// Fetches published file metadata directly from Steam's public WebAPI
    public func fetchMetadata(for input: String) async throws -> WorkshopItemMetadata {
        guard let workshopId = extractWorkshopId(from: input) else {
            throw NSError(
                domain: "SteamWorkshopService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "无法从输入中解析出有效的 Steam 工坊 ID: \(input)"]
            )
        }

        let apiURL = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0

        let bodyString = "itemcount=1&publishedfileids[0]=\(workshopId)"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "SteamWorkshopService",
                code: 502,
                userInfo: [NSLocalizedDescriptionKey: "Steam API 请求失败，状态码: \((response as? HTTPURLResponse)?.statusCode ?? -1)"]
            )
        }

        struct SteamAPIResponse: Decodable {
            struct ResponseBody: Decodable {
                struct Detail: Decodable {
                    let publishedfileid: String
                    let result: Int
                    let title: String?
                    let file_size: String?
                    let preview_url: String?
                    let tags: [Tag]?

                    struct Tag: Decodable {
                        let tag: String
                    }
                }
                let publishedfiledetails: [Detail]
            }
            let response: ResponseBody
        }

        let decoded = try JSONDecoder().decode(SteamAPIResponse.self, from: data)
        guard let detail = decoded.response.publishedfiledetails.first, detail.result == 1 else {
            throw NSError(
                domain: "SteamWorkshopService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "工坊中未找到对应壁纸或该壁纸为私密状态 (ID: \(workshopId))"]
            )
        }

        let tagNames = detail.tags?.map(\.tag) ?? []
        let rawSize = Int64(detail.file_size ?? "0") ?? 0

        // Determine type
        var inferred: WallpaperType = .unknown
        let lowerTags = tagNames.map { $0.lowercased() }
        if lowerTags.contains("video") {
            inferred = .video
        } else if lowerTags.contains("scene") {
            inferred = .scene
        } else if lowerTags.contains("web") {
            inferred = .web
        }

        return WorkshopItemMetadata(
            publishedfileid: detail.publishedfileid,
            title: detail.title ?? "未命名壁纸",
            previewURL: detail.preview_url,
            fileSize: rawSize,
            tags: tagNames,
            inferredType: inferred
        )
    }
}
