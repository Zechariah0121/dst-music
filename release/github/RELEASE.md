## 云间音乐 / DangoMusic 0.6.0-beta.3

Windows 10/11 64 位测试版。[下载与版本列表](https://github.com/Zechariah0121/dst-music/releases)。游戏 Mod 的固定工坊条目：[3836261433](https://steamcommunity.com/sharedfiles/filedetails/?id=3836261433)。

- 首页与歌单缓存按音源、账号隔离；重开先显示缓存，过期后后台刷新。
- 滚动时立即复用已有封面，切歌、隐藏和关闭时释放旧图片资源。
- 提高按钮文字对比度；ESC 主菜单提供单个原生“音乐播放器”入口；在线打开音乐设置，离线进入连接页并重读连接。
- 打开模组目录会尝试显示已有窗口，并反馈是否需要按 Alt+Tab。
- 新增 GitHub 版本检查和固定工坊入口，可关闭自动检查，不会自动安装。
- 原生音频下载失败后，再次点击播放可重新尝试。

本地后端、原生音频、Lua 离线契约与打包检查已通过；游戏内已检查旧入口、连接、主题切换、缓存和滚动等部分流程。新的 ESC 主菜单入口和网易云推荐封面修复已通过离线或后台验证，游戏内仍待验收；真实工坊订阅更新等也待验收。自动化检查不代表完整游戏验收。

### 下载与更新

- **Windows-Companion.zip**：给已经订阅 Mod 的玩家。先退出旧后台，再完整解压新版，运行“连接工坊Mod.cmd”，然后启动播放器。
- **Release.zip**：完整包，含工坊上传目录、配套播放器、对应源码、简介和许可。
- **Source.zip**：该版本对应源码与构建脚本，不含登录状态和运行缓存。
- **SHA256SUMS.txt**：下载文件的 SHA-256 校验值。

Steam 负责更新游戏 Mod；Windows 配套程序需要重新启动新版。工坊内置包更新后，也可再次运行“一键启动播放器.cmd”。旧手动版切换到一键版可能需要重新扫码登录。

音频播放仍受网易云或 QQ 账号权限、试听和接口限制。许可证与第三方署名随包提供，DangoMusic 衍生部分保留 GPLv3 对应源码及条款。

### English

This Windows beta improves account-separated home/playlist caching, scrolling artwork, resource cleanup, button readability and a native-style ESC main-menu entry. It adds GitHub release checks and clearer folder-opening feedback, and allows explicit retry after a failed native audio download. Update checks never install software automatically.

Use **Windows-Companion.zip** with the subscribed client Mod. **Release.zip** contains the complete Workshop upload bundle, companion, source and notices. Playback remains subject to each service's account permissions and API availability. Some in-game flows were checked; the new ESC entry and recommended artwork fix still await in-game validation. Real Workshop update behavior and other scenarios still require validation.
