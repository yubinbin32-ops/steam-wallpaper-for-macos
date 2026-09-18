# Project Decisions

## [DEC-001] Mac 原生壁纸 App 架构选型与双轨管线方案

### 1. 背景 (Context)
Steam Wallpaper Engine 原生仅兼容 Windows。其创意工坊内壁纸分为四大类：Video（纯视频 MP4/WebM）、Scene（2D/3D 复杂交互实时场景）、Web（HTML5/WebGL）与 Application（exe）。
在 macOS 平台上，用户需要一款原生的动态壁纸管理与播放软件：用户只需粘贴工坊链接，系统自动鉴权下载并解析壁纸，支持在壁纸相册中一键无缝切换桌面。核心诉求是：原生 Swift 开发、界面精美、绝不卡顿、低能耗发热与高兼容性。

### 2. 决策 (Decision)
采用 Swift (SwiftUI + AppKit) 原生架构：
1. **下载引擎**：利用本地运行的 Steam 客户端控制台通道（`steam_osx +workshop_download_item 431960 <id>`），实现官方 CDN 极速下载，免除自建 SteamGuard 鉴权与账号泄露风险。
2. **底层渲染管线**：统一采用 Apple 原生 `AVPlayer` + `AVPlayerLooper` 硬件解码器（VideoToolbox）作为桌面底层置底渲染（Window Level = `.desktopWindow`）。
3. **类型分流策略**：
   - 对于 Video 壁纸：自动提取原版 4K MP4/WebM，秒入库秒播放，0 卡顿、CPU < 0.5%。
   - 对于 Scene 壁纸：Phase 1 自动提取其超清原画贴图（TEX 转 PNG）与无损 FLAC 原声音乐，标记场景特征；Phase 2 提供无缝 60fps 循环视频离线烘焙工具（方案 C），统一回流至 AVPlayer 播放。

### 3. 原因与替代方案取舍 (Rationale & Tradeoffs)
- **为何放弃方案 A（后台常驻 WebGL / WKWebView 实时计算 Scene）？**
  Scene 壁纸大量依赖 Windows DirectX/HLSL 定制着色器与上万粒子特效。在 Mac 后台持续跑 WebGL 相当于常驻 3D 网页游戏，会导致 Apple Silicon GPU 无法休眠、严重发热、掉电加快，且移植着色器存在大量报错黑屏风险。
- **为何统一至原生视频管线？**
  macOS 的 M 芯片拥有专属硬件多媒体引擎。统一成视频渲染管线后，无论多高码率的 4K 60fps 动态壁纸，功耗均接近待机，能做到 100% 不掉帧、不卡顿，配合全屏智能休眠可达到极致体验。

### 4. 影响与后果 (Consequences)
- 架构极度清爽纯粹，无任何第三方重型依赖；
- 内存严格控制在 50~80MB 之间，风扇不转；
- 用户仅需复制粘贴链接，全自动完成下载与入库，交互路径短且优雅。
