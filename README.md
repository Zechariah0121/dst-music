# 云间音乐 · 饥荒联机版音乐播放器

在《饥荒联机版》中浏览网易云音乐和 QQ 音乐歌单、搜索歌曲并控制播放，配有封面、悬浮歌词、歌曲卡片、动态岛和地区空间音效。客户端模组无需服务器或朋友安装，支持 Windows 10/11 64 位。

当前版本为 **0.6.0-beta.6**，对应 2026-11-22 的工坊更新：支持失效安装目录恢复、扫码后的有限次重试、主菜单音乐控制和运行中连接文件恢复。更新说明及下载见 [GitHub Releases](https://github.com/Zechariah0121/dst-music/releases)，固定订阅入口为 [Steam 工坊](https://steamcommunity.com/sharedfiles/filedetails/?id=3836261433)。两平台分别发布，请核对版本；详细验证与已知限制见 [发布说明](release/github/RELEASE.md)。

## 开始使用

1. 订阅并等待 Steam 下载完成。在「此电脑」搜索 **3836261433**，打开含 **一键启动播放器.cmd** 的模组文件夹并双击该脚本；多个结果时，选择 Steam 库下 `steamapps\workshop\content\322330` 中的那个。首次选择安装位置（可直接保留默认路径），随后会校验、解压随包播放器，连接模组并启动后台。以后沿用已记住的位置。
2. 在客户端模组启用本模组。beta.6 可在游戏主菜单点击 **音乐播放器**；进入世界后按 **F8**，或按 **ESC → 音乐播放器**。如果游戏已加载旧版 Lua，更新后先重启一次。后台离线时可在连接页重新读取连接；后台已经关闭时仍需双击 Windows 启动入口。
3. 在播放器账号页选择网易云或 QQ 音乐，用对应手机 App 扫码确认。账号分别保存；切换浏览来源不会中断另一来源正在播放的歌曲。

以后可再次双击启动；也可用 **自启动设置.cmd** 勾选并保存，使后台随 Windows 登录启动。默认关闭，首次至少需要双击一次。退出后台可运行 `windows-player/停止配套播放器.cmd`。旧手动版不会自动迁移，首次切换可能需要重新扫码。完整说明见 [工坊版使用指南](release/workshop/README.zh-CN.md)。

## 功能与限制

- 左上角按钮默认显示，可在设置中隐藏；仍可用快捷键或 ESC 主菜单中的音乐播放器入口打开。网易云与 QQ 使用统一布局和各自主题色；玻璃效果为半透明分层高光，不是真正的背景模糊。
- 歌词、快捷键、界面和空间音效可调整。普通逐行歌词的逐词动画为估算，真实逐词同步需要来源提供时间戳；空间效果处理歌曲，不添加环境音轨。
- 播放受账号权限、版权、地区、会员和试听限制。部分手机端可播的 QQ 歌曲可能不返回播放地址，不能保证全曲库可播。
- 版本检查读取 [GitHub Releases](https://github.com/Zechariah0121/dst-music/releases)，可手动检查；启动及每六小时的自动检查可关闭，不会自动安装。工坊入口由 Steam 更新订阅内容。
- 不支持导入本地音频、跨玩家同步播放或 Mac/Linux。请勿分享 `.state`、连接文件或私人缓存。

## 从源码构建

需要 Windows 和 Python 3.10+：运行 `python tools/prepare-runtime.py` 准备固定运行库，再运行 `runtime/python/python.exe tools/build-workshop.py`。产物位于新的 `dist/*-workshop-*` 目录。构建器不上传内容。协议见 [PROTOCOL.md](PROTOCOL.md)，测试范围见 [VALIDATION.md](release/workshop/VALIDATION.md)。

维护者发布时，先更新版本标记、Mod 信息、构建器版本和 `release/github/RELEASE.md`，完成本机游戏验收后再推送同名 `v版本号` 标签。GitHub Actions 会检查版本一致性、运行后端与打包测试，再构建 Windows 配套包、完整包及源码并创建 Release；beta 标签发布为预发布。手动运行工作流只构建供下载的 Actions 产物，不创建 Release，也不上传 Steam。每次构建和发布的实际结果见 [Actions 记录](https://github.com/Zechariah0121/dst-music/actions/workflows/release.yml)。

本项目由 Zcc 制作，非网易云、QQ 音乐、Klei 或 DangoMusic 官方产品。包含基于 [Sorihiko / DangoMusic](https://github.com/Sorihiko/DangoMusic) 的 GPLv3 衍生音频与 QQ 互操作实现；对应源码、GPL 正文和其他组件许可随包提供，详见 [许可说明](release/workshop/LICENSE-DECISION.md) 与 [组件来源](helper/native-deps/SOURCES.md)。
