# 来源与许可

本说明保留各组件已有的许可和署名，不把整个项目、所有独立组件或图像素材自动改为同一个许可证，也不限制第三方许可证已授予的权利。

## DangoMusic 衍生音频部分

原生音频实现包含从 Sorihiko/DangoMusic 移植、修改的 GPL-3.0 代码。该部分及受其条款覆盖的组合作品按 GPLv3 要求提供；“参考自 DangoMusic”的页面署名不能替代许可、修改说明和对应源码。

- 上游：https://github.com/Sorihiko/DangoMusic
- 固定提交：`ffd88ffc9f4b4af30ef7550eb9781468ab180c31`
- 许可证全文：配套包/源码包 `helper/native-deps/DangoMusic.LICENSE.txt`；工坊根 `licenses/DangoMusic.LICENSE.txt`。
- 原生实现：`helper/NativePlayer.cs`、`NativeDSP.cs`、`EnvironmentDSP.cs`，由 `NativePlayer.ps1` 编译运行。
- 修改说明、原始参考文件和依赖摘要：`helper/native-deps/SOURCES.md` 及同目录 `.reference.kt`。
- 完整实现和构建脚本随同版本源码 ZIP 一并分发，位于工坊 `source/`；Windows 配套包也保留这些源码。不存在只提供二进制、另行索取源码的步骤。

本说明不通过按文件或 ZIP 分开摆放来缩小 GPL 依法适用的范围；对应源码按适用条款保留修改、再分发权利。完整条款以随附 GPLv3 正文为准。

## 其他组件与素材

NAudio、QRCode、Node.js、CPython、Pillow 及其所含组件保留各自原始许可证和通知，详见 `THIRD-PARTY-NOTICES.md`。

工坊封面和图标来自作者提供的 `dangomusic.gif`，原 GIF 与选帧记录在源码包 `release/workshop/` 内。图片中的第三方标识和角色不因代码许可证而重新授权。游戏字体从玩家自己的游戏安装中读取，不随包分发。

本项目不是 DangoMusic、网易云或 Klei 的官方产品。
