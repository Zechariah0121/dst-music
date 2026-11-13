# 第三方来源与许可

以下通知保留各组件已有权利与义务。本包没有把所有独立组件或素材统一改为同一种许可证；含 GPL 衍生代码的原生音频部分继续遵守相应条款，完整对应源码随包提供。具体说明见工坊包的 `LICENSE-DECISION.md`。

| 组件 | 来源与版本 | 随包许可/源码 |
|---|---|---|
| DangoMusic 环境音频与归一化参考 | [Sorihiko/DangoMusic](https://github.com/Sorihiko/DangoMusic)，固定提交 `ffd88ffc9f4b4af30ef7550eb9781468ab180c31` | `helper/native-deps/DangoMusic.LICENSE.txt`（GPL-3.0）、两份 `.reference.kt`、`SOURCES.md`；修改实现为 `helper/EnvironmentDSP.cs`、`NativeDSP.cs` 及相关源码 |
| NAudio | Mark Heath，2.2.1，官方 NuGet | `helper/native-deps/NAudio.LICENSE.txt`（MIT）、`SOURCES.md`、三个DLL |
| QRCode | 项目内vendor头部标注的QRCode实现 | `helper/public/vendor/qrcode-LICENSE.txt`（MIT）及 `qrcode.js` 版权头 |
| Node.js | 官方Windows x64发行版，24.22.2 | `runtime/node/LICENSE`，包含Node和它所含组件的许可；官方归档和摘要见 `runtime/SOURCES.json` |
| CPython | 官方Windows embeddable发行版，3.13.17 | `runtime/python/LICENSE.txt` 及发行版内许可；来源见 `runtime/SOURCES.json` |
| Pillow | 官方 PyPI Windows wheel，13.0.0 | `runtime/python/Lib/site-packages/pillow-13.0.0.dist-info/` 内LICENSE及所含组件通知；来源见 `runtime/SOURCES.json` |

运行库归档摘要与官方HTTPS元数据比对；并未独立验证Sigstore证书链或签名。构建信息和摘要固定在 `tools/runtime-lock.json`。

静态UI图集由 `helper/asset-image.py` 的几何绘图生成。便携图片编译不再需要或分发 ktools/ktech。`helper/ktex.py` 的DXT5解码使用Pillow，原始KTEX编码和字形预乘逻辑随包提供。

2026-11-09 的工坊封面和 Mod 图标使用作者 Zcc 提供的 `dangomusic.gif`，保留原 GIF，并提取第0帧生成静态预览和图标。来源摘要、尺寸与处理记录见 `release/workshop/ARTWORK.json`；这份用户提供的图片不因项目代码的许可证而自动获得 GPL 授权，不据此宣称拥有图中第三方标识或角色的权利。

游戏字体仅在运行时从用户本机的DST安装中读取，保留其原始许可与本机来源记录，不随本包分发。歌曲、封面与账号内容也不随包分发。
