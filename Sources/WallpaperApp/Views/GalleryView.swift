import SwiftUI
import WallpaperCore

struct GalleryView: View {
    @ObservedObject var store = WallpaperStore.shared
    @ObservedObject var engine = DesktopEngine.shared
    @ObservedObject var power = PowerManager.shared

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Download Input Area
            DownloadBarView()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Main Content Area
            if store.filteredWallpapers.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.filteredWallpapers) { item in
                            WallpaperCardView(
                                item: item,
                                isActive: store.activeWallpaperId == item.id
                            ) {
                                store.selectWallpaper(item)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            // Footer / Power Status
            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let logoURL = Bundle.main.url(forResource: "logo_white", withExtension: "png") ?? Bundle.main.url(forResource: "logo", withExtension: "png"),
               let nsImage = NSImage(contentsOf: logoURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Steam Wallpaper (Mac)")
                    .font(.system(size: 14, weight: .bold))
                Text("已就绪 \(store.wallpapers.count) 款壁纸 · 原生 60fps 硬解渲染")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Mute / Volume toggle
            Button {
                engine.isMuted.toggle()
            } label: {
                Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(engine.isMuted ? .secondary : .accentColor)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(engine.isMuted ? "已静音（点击开启壁纸原声）" : "壁纸声音播放中（点击静音）")

            if !engine.isMuted {
                Slider(value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.volume = Float($0) }
                ), in: 0...1)
                .frame(width: 70)
            }

            // Pause/Play toggle
            Button {
                if engine.isPlaying {
                    engine.pause()
                } else {
                    engine.resume()
                }
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(engine.isPlaying ? "暂停播放" : "恢复播放")

            // Refresh button
            Button {
                store.refreshWallpapers()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("刷新本地壁纸库")
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles.tv")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("暂无已下载壁纸")
                .font(.system(size: 14, weight: .medium))
            Text("请在上方粘贴 Steam 创意工坊链接，系统将自动高速下载并应用。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerBar: some View {
        HStack {
            // Power state
            HStack(spacing: 5) {
                Circle()
                    .fill(power.isSuspendedForPowerSaving ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)

                Text(power.isSuspendedForPowerSaving ? "全屏智能休眠中（已释放 GPU）" : "桌面渲染活跃 (硬解 CPU < 0.5%)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle(isOn: $power.pauseOnFullScreen) {
                Text("全屏应用时智能暂停")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
        }
    }
}
