# 工坊发布准备：0.6.0-beta.6

当前线上为 beta.5，本地候选为 beta.6，尚未执行 Steam 或 GitHub 上传。更新目标为已有条目 **3836261433**，不要另建重复条目。

## 上传内容怎么选

在上传器中选择新构建的 **workshop-mod** 作为内容根；根目录应能直接看到 `modinfo.lua`、`modmain.lua` 和 `一键启动播放器.cmd`。使用 `Workshop-Upload.zip` 时先解压，再选择里面的 `workshop-mod`。不要选择整个构建资料目录，也不要把 ZIP 本身作为内容目录。

预览图使用 `modpreview.gif`，上传器只接受静态图时使用 `modpreview.png`。更新说明分别为 `UPDATE-NOTES.zh-CN.txt`、`UPDATE-NOTES.en.txt`；历史记录见 `CHANGELOG.txt`。

干净内容目录包含一键启动入口、`windows-player` 配套后台和安装说明、`source` 对应源码、游戏资源及第三方许可。构建清单、测试日志和演示素材放在内容目录之外。不要从运行中的订阅目录复制上传，以免带入账号、连接文件或私人缓存。

## 本次验证

安装目录恢复、账号保存重试、静态计时和连接修复已通过自动化检查。初版候选经过实际构建、隐私扫描、ZIP CRC 与摘要校验；真实升级保留账号和设置。游戏日志确认 beta.6，主菜单网易播放、暂停、继续、关闭和重新打开已检查，入口已避让本机其他菜单 Mod。最终文件及摘要以新构建目录的 `BUILD-MANIFEST.json`、`SHA256SUMS.txt` 为准。

真实新扫码、恢复窗口鼠标交互、Steam 更新全过程、Windows 登录自启动和其他电脑仍待验收。旧 QQ 登录能够读取歌单，但播放提示失效；本轮 QQ 搜索接口返回 HTTP 500，尚未修复。音频引擎未改动，历史延迟数据不是本次重测。完整事实和限制见 `VALIDATION.md`。

## 简介页面

`WORKSHOP-DESCRIPTION.txt` 与 `WORKSHOP-DESCRIPTION.en.txt` 是精简后的中英文简介，按当前在线 beta.5 的使用方式编写。英文已保存；中文保存被 Steam 拒绝，当前条目等待自动内容审核并暂时隐藏，中文线上尚未更新。等待页面恢复编辑后再提交中文文案。

源码、GPL 正文与第三方署名继续随包提供，见 `LICENSE-DECISION.md`、`THIRD-PARTY-NOTICES.md` 及 `source/`。本地构建不会代替线上发布确认，也不会改动工坊公开可见性。
