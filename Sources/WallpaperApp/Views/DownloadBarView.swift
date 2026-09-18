import SwiftUI
import WallpaperCore

struct DownloadBarView: View {
    @ObservedObject var store = WallpaperStore.shared
    @State private var inputURL: String = ""
    @State private var isDownloading: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))

                    TextField("粘贴 Steam 创意工坊链接或输入壁纸 ID（下载时需打开 Steam 客户端）...", text: $inputURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .default))
                        .onSubmit {
                            startDownload()
                        }

                    if !inputURL.isEmpty {
                        Button {
                            inputURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                Button {
                    startDownload()
                } label: {
                    HStack(spacing: 5) {
                        if isDownloading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isDownloading ? "处理中" : "下载并提取")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloading)
            }

            // Download Status Banner
            switch store.downloadState {
            case .idle:
                EmptyView()
            case .parsing:
                statusLabel(icon: "magnifyingglass", text: "正在解析 Steam 工坊元数据...", color: .secondary)
            case .downloading(_, let msg):
                statusLabel(icon: "arrow.down.circle", text: msg, color: .blue)
            case .unpacking:
                statusLabel(icon: "cube.box", text: "正在解包并检测壁纸资产...", color: .purple)
            case .completed(let item):
                statusLabel(icon: "checkmark.circle.fill", text: "《\(item.title)》已下载并设为桌面壁纸！", color: .green)
            case .failed(let err):
                statusLabel(icon: "exclamationmark.triangle.fill", text: "错误: \(err)", color: .red)
            }
        }
    }

    private func statusLabel(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Spacer()
        }
        .foregroundColor(color)
        .padding(.horizontal, 4)
    }

    private func startDownload() {
        let text = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isDownloading = true
        Task {
            await store.downloadAndApply(linkOrId: text)
            await MainActor.run {
                isDownloading = false
                if case .completed = store.downloadState {
                    inputURL = ""
                }
            }
        }
    }
}
