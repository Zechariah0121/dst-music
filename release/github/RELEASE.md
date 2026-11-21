## DangoMusic 0.6.0-beta.6 · 2026-11-22

Windows 10/11 64 位测试版，与 [Steam 工坊 0.6.0-beta.6](https://steamcommunity.com/sharedfiles/filedetails/?id=3836261433) 同步。本次 GitHub 更新包含上一版 beta.3 之后的累计改动。

### 本次 beta.6 更新

- **安装目录恢复**：旧目录已删除或磁盘不可用时，一键启动器支持重新选择目录并恢复安装；取消保留原位置记录和自启动设置。
- **扫码登录重试**：扫码确认后遇到短暂网络或账号保存错误，会有限次自动重试，也可使用「重试确认」，减少不必要的重复扫码。
- **主菜单播放**：无需先进入世界，就能打开播放器、播放、暂停、继续和关闭面板；调整入口布局以减少与其他模组按钮重叠。
- **连接恢复**：后台运行时自动尝试恢复丢失的连接文件，游戏离线时重读配置。后台已关闭时，仍需运行 Windows 启动入口。
- **安装说明**：先展示五步安装流程，突出「此电脑搜索 3836261433」找到模组文件夹的方法。

### 自 GitHub beta.3 以来的其他变化

- **WASAPI 共享输出**成为默认，初始化失败时回退 WaveOut；改进暂停恢复、进度跳转、曲尾计时和切歌时的设备释放流程。
- **首次选择安装位置**：可保留默认目录，也可选择其他磁盘；程序、账号、设置与音乐缓存保存在所选位置，后续启动和升级沿用它。
- 停止入口及可选 Windows 自启动跟随已记录的安装位置，自启动默认关闭。

### 安装与更新

**工坊玩家优先通过 Steam 更新，配套后台已经包含在工坊下载中，无需另下 GitHub 安装包。**

1. 关闭饥荒，并运行模组目录中的 `windows-player\停止配套播放器.cmd`。旧手动版先在原目录运行 `停止播放器.cmd`。
2. 等 Steam 更新完成。在「此电脑」搜索 **3836261433**，打开含 `一键启动播放器.cmd` 的模组文件夹；有多个结果时，选择 Steam 库下 `steamapps\workshop\content\322330` 中的那个。
3. 双击 `一键启动播放器.cmd`，等待新版后台启动，再打开游戏。主菜单可点击「音乐播放器」，进入世界后可按 **F8**。

只重启游戏不会替换仍在运行的旧后台。已有一键版沿用原安装目录并保留账号和设置；原目录数据被删除后，重装不能找回账号和缓存，可能需要重新扫码。

### 下载内容

- **Windows-Companion.zip**：独立 Windows 后台，供手动安装或更新；工坊一键启动用户通常不需要另下。
- **Release.zip**：完整归档，含工坊内容目录、配套后台、对应源码和说明文件。
- **Source.zip**：对应源码与构建脚本，不含账号、连接凭据或私人缓存。
- **SHA256SUMS.txt**：下载文件的 SHA-256 校验值。

### 验证与已知限制

beta.6 本地检查通过：80 项 Node 回归、4 套 Lua 离线检查、3 套 PowerShell 启动器检查，以及 19 项打包与隐私检查。主菜单网易云播放、暂停、关闭重开和继续播放已实机检查；已有一键版升级保留账号文件与设置。

QQ 旧登录可能仍可读取歌单，但播放时要求重新登录；QQ 搜索上游接口也出现过不可用。本次没有完成真实新二维码登录及保存重试的全流程验收，不能视为所有 QQ 登录或播放问题已解决。其他电脑、Windows 登录自启动、Voicemeeter 和精确声音与画面延迟仍未验证。播放受平台权限与接口可用性限制。

### English

This Windows 10/11 x64 beta matches the Steam Workshop beta.6 release and includes cumulative changes since GitHub beta.3.

**New in beta.6:** recover an unavailable installation by choosing another folder; retry transient failures after QR authorization; control playback and close the panel from DST's main menu; restore missing connection files while the companion is running; and follow clearer setup instructions beginning with a This PC search for **3836261433**.

**Also included since beta.3:** default WASAPI shared output with WaveOut fallback on initialization failure; improved pause, seek, end-of-track timing and output cleanup; a first-run installation-folder picker; and remembered storage for the program, accounts, settings and music cache. Optional Windows startup remains off by default.

**Workshop users:** close DST and stop the old companion, wait for Steam to update, then run `一键启动播放器.cmd` in the Workshop mod folder. The companion is included with the subscription; a separate GitHub download is normally unnecessary. Restarting only DST does not replace a running companion. Existing one-click installations retain their location and data; reinstalling cannot recover deleted account data or cache.

**Assets:** Windows-Companion is the standalone player, Release is the complete archive, Source contains the corresponding source and build scripts, and SHA256SUMS lists download checksums.

Local automated checks and actual main-menu NetEase play/pause/close/resume checks passed. Old QQ credentials may require signing in again for playback, and QQ search has experienced upstream failures. A fresh QR login and save-retry flow, other PCs, Windows login startup, Voicemeeter and precise audio-to-screen latency remain unverified.

### 源码与授权 / Source and notices

本项目非网易云、QQ 音乐、Klei 或 DangoMusic 官方产品。包含基于 [Sorihiko / DangoMusic](https://github.com/Sorihiko/DangoMusic) 的 GPLv3 衍生音频与 QQ 互操作实现；对应源码、GPL 正文与第三方署名随包提供，见 `source/`、`THIRD-PARTY-NOTICES.md` 和 `LICENSE-DECISION.md`。

Not an official product of NetEase, QQ Music, Klei or DangoMusic. Corresponding source, GPL terms and third-party notices for the derivative components remain included.
