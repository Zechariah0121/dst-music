# 本机音乐桥协议 · 0.6.0-beta.5 测试候选

## 0.6 双音源扩展（本地测试候选）

- `settings.player.musicSource` 为 0（网易云）或 1（QQ 音乐），只控制浏览音源，不切断另一来源正在播放的歌曲。
- `GET /api/status` 返回 `provider` 和该来源的公开 `account`；status/playlists/discover/search 可通过 `?provider=netease|qq` 显式指定。login/start、logout 以 JSON `provider` 指定。旧请求省略 provider 时使用所选音源。
- 网易云歌曲/歌单保留数字字符串 ID。QQ 歌曲为 `qq:<MID>`，歌单为 `qq:playlist:<ID>`，排行榜为 `qq:chart:<ID>`，我喜欢为 `qq:liked:<账号ID>`。播放、队列、媒体续签、封面与歌词按 ID 自身来源路由，不能按当前浏览来源猜测。
- QQ 凭据只存 `.state/account-qq.json`，网易云保留 `.state/account.json`；两边独立登录、退出和清理缓存，不向游戏返回 cookie、票据或续期凭据。QQ 使用平台返回的 PNG 二维码，经 MQTT 确认并核验账号后保存登录。
- QQ `login/start` 返回 `{ok,key,provider}`，不保证有 `url`。游戏仍用 `GET /api/login/artwork?key=...` 读取图集；本机 `GET /api/login/image?key=...` 返回 PNG。两个接口仍需本机 token，禁止在发布包中携带二维码或登录状态。
- `POST /api/login/cancel {key,provider?}` 幂等关闭对应扫码会话；关闭屏幕、离开登录页及切源时调用。未知 key 不影响其他登录，会话有独立超时和关闭清理。
- QQ 的 QRC 解析后沿用秒制行/词时间；无逐词数据时回退普通 LRC，不伪造逐词时间。MP3 仍使用现有原生播放与环境 DSP，VIP/试听/版权限制沿用平台结果。
- 历史网页诊断播放器仍显式管理网易云，QQ 的音源切换和扫码入口在游戏面板中。

仅监听 127.0.0.1:17863。所有 /api/* 请求使用 Authorization: Bearer TOKEN 或 ?token=TOKEN；校验 Host/Origin。错误统一 {ok:false,error:"中文说明"}。网易云 Cookie 仅保留在后台。

## 游戏慢请求与连接（0.6.0-beta.2）

游戏 `TheSim:QueryServer` 有约 5 秒低速超时风险。游戏桥对慢请求附加 `gameAsync=1`：GET 的 discover、search、playlists、playlist、lyrics、lyric-glyphs、artwork、login/artwork、login/check，以及 POST 的 login/start、control 的 play/next/previous。普通调用不加该参数，保留原 HTTP 响应契约。快速完成时直接返回原结果；否则服务端约 1 秒返回 `{ok:true,pending:true,requestId}`，工作继续在后台进行。

- 服务端以 16 随机字节生成 32 位小写十六进制 ID；客户端验证 ID 后每 0.5 秒请求固定 `GET /api/request/result?id=...`，不跟随服务端返回的任意 URL。未完成时返回相同收据；完成时返回 `{ok:true,pending:false,response:<原响应>,status:<原HTTP状态>}`。完成结果可重取直到过期；ID 无效或过期返回 410。
- 任务自创建起 90 秒过期；活动任务上限 32，超限返回 429。游戏侧慢请求超时为 45 秒，普通请求为 8 秒。关闭或超时会向固定 `POST /api/request/cancel` 发送 `{requestId}`；该接口校验 32 位小写十六进制，未知或已过期 ID 也返回成功。取消丢弃结果，并清理被丢弃的登录会话；不保证中断已经执行的上游操作。若初始收据在关闭后才到达，桥也会尝试取消。
- 请求、轮询和取消都经过同一本机 token、Host 与 Origin 检查。ID 不是鉴权凭据；不得把 token 或连接配置放入分发包。
- `Controller:Reconnect` 重新读取 `scripts/dangomusic_connection.lua`，校验固定 loopback 地址和 token；有效时关闭旧桥、取消旧请求、清除相关状态并刷新设置和状态。无效配置保留旧桥并提示先启动播放器。游戏已加载旧 Lua 时须先重载新版一次；新代码加载后可通过游戏入口重新读取连接。
- `settings.player.showTopLeftButton` 是布尔值，默认 true；false 隐藏左上按钮，不移除快捷键与 ESC 主菜单入口。`POST /api/open-mod-folder` 只接受空 JSON 对象 `{}`，拒绝任何路径参数；后台打开配置的运行时 Mod 目录，仍须通过普通 API 鉴权。

以上是当前源码契约和回归覆盖范围；beta.2 实际游戏内连接、界面和性能仍待验收。

## beta.3 客户端与更新行为

首页和歌单缓存由 HUD 生命周期持有，按来源和账号隔离，保留五分钟；重开界面可先显示缓存并在后台刷新，刷新失败保留旧内容。封面资源复用并在生命周期结束时回收。ESC 主菜单提供单个原生“音乐播放器”入口：在线时打开音乐设置，离线时进入连接页并重读连接；系统设置页不添加按钮，菜单按实际项目数调整间距以兼容追加项目。打开模组目录复用已有窗口并尝试前台聚焦，被遮挡时可用 Alt+Tab。原 ESC 设置页的两个入口曾实机检查，新主菜单入口已有真实 `widgets/menu.lua` 的离线入口、焦点和重建测试，尚待重进游戏验收。

版本检查读取固定 GitHub 仓库 `Zechariah0121/dst-music` 的 Releases；工坊条目 `3836261433` 是固定访问入口，订阅内容由 Steam 更新。启动及每六小时自动检查可关闭，也可手动检查；不会自动安装。检查结果取决于网络和实际发布状态。原生音频下载失败后，显式播放可发起重试。

## 账号与曲库

- GET /api/status → {ok,account:null|{id,nickname},playerConnected,playerEngine:"native"|"browser"|null,player:{track,playing,position,duration,volume,error},revision,mode,settingsRevision,sampledAt}。时间单位秒；sampledAt 为 Unix 毫秒，position 为当前采样估计值。
- POST /api/login/start {} → {ok,key,url}；GET /api/login/check?key=... → {ok,status:"waiting"|"scanned"|"expired"|"success",account?}。仅接受当前会话 key。
- 桥接明确将空 Lua 表编码为 JSON 对象；为兼容已加载的旧 Mod，仅 login/start 和 logout 接受空数组 []，其他端点及非空数组仍拒绝。
- GET /api/login/artwork?key=... → {ok,asset:{atlas,image}}，生成游戏可加载二维码。
- POST /api/logout 清除账号并停止播放。
- GET /api/playlists → {ok,playlists:[{id,name,trackCount,cover?}]}。
- GET /api/playlist?id=...&offset=0&limit=50 → {ok,tracks,total,offset}，limit 最大100，完整歌单缓存供队列使用。
- GET /api/queue?offset=0&limit=100 → {ok,tracks,total,offset,hasMore,currentIndex,currentTrackId,queueRevision}。currentIndex 从0开始，空队列为-1；队列更换时递增版本，同队列切歌不递增。只返回曲目元数据。
- GET /api/discover?section=recommend|charts → {ok,playlists}。
- GET /api/search?q=...&offset=0&limit=50 → {ok,tracks,total,offset}。
- GET /api/lyrics?trackId=... → {ok,trackId,timing:"word"|"line"|"none",lines:[{start,end,text,words:[{start,end,text}],translation?}]}。时间单位秒；LRC 不伪造逐字时间戳。
- GET /api/lyric-glyphs?trackId=... → {ok,trackId,asset:{atlas,image},fonts:{mono,smooth},missing:[]}。每种 font 含 size/lineHeight/baseline/glyphs；glyphs 以 Unicode 字符为键，值含 core/near/far 图片名、advance/blank，以及 layers.{core,near,far}.{width,height,offsetX,offsetY,pixelScale}。布局统一为30像素逻辑字号；字芯以2倍密度直接采样源字体，近远光晕为1倍密度、独立大小和偏移，共用基线。顶层 width/height/offsetX/offsetY 是字芯兼容字段。该接口与歌词独立请求，生成失败仍显示普通文字；不改变歌词时间。资源只取自本机已安装游戏字体，不含登录凭据，源字体分辨率仍限制细节。
- GET /api/artwork?trackId=... 或 ?playlistId=... → {ok,asset:{atlas,image}}；仅允许后台已知封面，不可变哈希文件同步到带本项目标记的安装目录。

Track = {id,name,artists:string,duration:秒,cover?,trial?}。必须显示试听状态；权限或版权错误不得替换为其他歌。

## 播放与设置

- POST /api/control：{action:"play",playlistId,trackId} 或 {action:"play",source:"search",trackId}；{action:"pause"|"resume"|"toggle"|"next"|"previous"}；{action:"volume",value:0..1}；{action:"seek",value:秒}；{action:"mode",value:"loop"|"single"|"shuffle"}。
- 队列点歌：{action:"play",source:"queue",trackId,queueRevision?}，从当前实际队列选曲；过期版本返回409并保持当前播放，仍按账号权限获取音频。循环模式在 status 顶层的 mode，不在 player 内。
- GET /api/settings → {ok,settings,settingsRevision,schema}。schema 是 lyrics/player/card/island 的字段定义，含 type/default/min/max/integer/consumer，以及不支持项的 supported:false/reason。
- POST /api/settings 接受部分嵌套补丁，如 {lyrics:{scale:1.2}}。严格校验并保存；不支持项不能改成非默认值。
- POST /api/environment 接受完整 {water:boolean,cave:boolean,indoor:boolean,rain:0..1,region}，返回 {ok,expiresAt}。region 为 surface/cave/lunar/ocean/ruins/atrium/forest；cave/ruins/atrium 要求 cave=true，其余要求 false。兼容旧四字段客户端：未提供 region 时从 cave 推导。无效样本不覆盖有效样本。内存缓存5秒，过期回退 surface、无雨；客户端每1.5秒只读采样。DST water/indoor 发送 false，不把船/树荫误判为水下/室内。
- 地区采用当前本地玩家 areaaware 的标签与原生桦树林 room 身份；海面单点 Map:IsOceanAtPoint(...,true) 包含船。中庭优先于远古，月岛优先于海面；未知模组区域退回默认。areaaware 原有移动阈值和采样间隔会带来边界切换延迟。

## 原生音频进程

- POST /api/player/claim {clientId}，同ID重入有效；其他活跃ID拒绝，10秒无心跳才能换所有者。原生ID为 native_ 前缀。
- GET /api/player/state?clientId=... → {ok,audioRevision,desired:{revision,seekRevision,track,mediaUrl,playing,volume,position,audio}}；可追加 after=audioRevision&wait=8000，在版本相同且等待期间无变化时最多等待8秒。控制、音频设置、环境变化和环境失效即时唤醒；客户端断开释放等待，最多8个并发等待。省略after立即返回，兼容旧客户端。mediaUrl必须本机相对地址。
- audio={baseVolume,normalize,gainDb,peak,env:{enabled,water,cave,indoor,rain,region,strength}}。环境变化不增加 revision/seekRevision，也不重载歌曲。原生音频在80ms内逐样本过渡；停止环境效果后清除残留尾音，稳定状态精确旁路。
- player.envLunar/envOcean/envRuins/envAtrium/envForest 分别控制对应预设；envCave 控制普通洞穴。关闭特定地下预设时回退普通洞穴（若也关闭 envCave 则回退 surface），地表区域关闭后回退 surface。envRain 独立于地区开关，envAudio/envStrength 控制整体。
- POST /api/player/report {clientId,revision,position,duration,playing,error?,ended?,gameRunning?}；报告独立于状态长轮询，旧revision不能覆盖新播放状态。ended先确认接收，再有序加载下一曲，慢上游不阻塞续租；每个revision仅处理一次。
- gameRunning 为可选布尔值。原生端在独立后台任务中每秒检查 Windows DST 客户端进程，不统计专用服务器；枚举失败时省略字段。当前播放器所有者已报告 true 后再报告 false，服务端暂停并保留队列、歌曲和进度，同时阻止待完成选歌重新开始播放。即使播放 revision 已旧，游戏进程状态仍独立处理。重复 false 不再次暂停，true 不自动恢复；更换或重新取得播放器租约时重置观测状态。没有此字段的旧客户端仍可使用。
- GET /api/media?trackId=...&token=... 串流音频，支持Range；外部地址仅由后台对应来源接口提供，并按来源校验。
- 网易云媒体域名限于 HTTPS 的 *.music.126.net；QQ 地址单独按固定域名规则校验，并将无端口 HTTP 地址升级为 HTTPS。系统DNS全部为198.18/15时，仅对该域名通过固定HTTPS DNS服务取得公网IPv4；首选250ms未返回或失败时提前启动备用路径，使用首个验证通过的答案、取消另一请求。最多缓存60秒／64个域名；请求固定IP并保留域名TLS校验。私网／混合异常DNS响应不因此获得放行。
- 原生错误报告不直接回传进程异常字符串。当前歌曲与revision对应的媒体下载错误可保留受控中文原因，其余使用本机音频提示；换歌不会沿用旧下载原因。
- GET /health → {ok:true,name:"dst-music-bridge"}，无秘密。

原生进程的MP3路径采用异步下载与逐帧解码 → PCM临时磁盘+固定内存读前缓存 → NAudio PCM/DSP → WASAPI共享输出，初始化失败时回退WaveOut。两者请求总缓冲60ms，实际输出延迟取决于设备。音频回调不等待网络或磁盘读取；欠载填零且报告进度只计算真正播出的PCM。未缓冲位置的seek等待数据；非MP3仍整文件下载后Media Foundation解码。压缩/PCM缓存各256MiB，内存读前16×64KiB；换曲取消旧下载并清理缓存。无浏览器依赖；父服务退出后音频进程退出。WASAPI暂停在本机记录已播位置、异步停止并重建设备，避免暂停静音被计入歌词时间；不会改变协议seekRevision。WaveOut保留其原生暂停方式。显式seek、选曲和租约恢复才增加seekRevision。

暂停/恢复/音量/设置直接处理，设置磁盘写入另行串行化，不排在慢选歌后；选歌仍按顺序推进队列，加载期间收到的暂停会保留到新曲。WASAPI由专有STA创建和释放，控制线程仅读缓存时钟；切歌在旧设备停止后才启动新设备，重建期间报告playing=false。自然EOF依据provider返回0判定，保留曲尾进度，不依赖已重置的设备时钟。地区DSP位于EnvironmentDSP.cs，生产编译包含NativePlayer.cs、NativeDSP.cs、SharedAudioOutput.cs、EnvironmentDSP.cs与GameProcessMonitor.cs。

诊断时可仅给播放器进程设置DANGO_AUDIO_OUTPUT=wasapi（强制共享、失败不回退）、waveout（兼容输出）或auto（默认优先共享）；不写入系统环境变量。选用的输出在native.log记录为native_audio output=wasapi-shared或waveout，故障日志不包含设备名、媒体地址或凭据。仅初始化失败自动回退；运行中的设备断开仍报告播放失败，不会无限重试。

## 生命周期与安装

首次安装产生或保留 .state/bridge.json 和 mod/scripts/dangomusic_connection.lua，不得分发真实凭据。安装器记录 .state/install.json；启动器使用包内Node/Python，通过 --python 与 --runtime-mod-dir 传递路径，后台据此同步封面/二维码。资源编译使用包内Pillow和KTEX编解码，不需要外部ktech。

0.5.1 工坊测试版通过 Connect-Workshop.ps1 连接已订阅的 Mod。只允许带 music_workshop_identity.json（schema=1、id=zcc-dst-music、channel=workshop-beta、可选version）的 Steam 新 UGC /322330/数字ID 或旧 mods/workshop-数字ID 目录。公开身份标记不是秘密；私有 token 仍在本机独立生成，连接器不复制或覆盖订阅源码。install.json 记录 mode、gameDir、modDir；Start 校验目标并在启动时恢复连接Lua，使用 --fonts-path 指定真实游戏 fonts.zip，不从 UGC 目录推算字体。动态资源下次请求时从配套包本机缓存重发至订阅目录；游戏已加载旧版 Lua 时需要重载一次；新版加载后可通过 Reconnect 重读连接。路径守卫拒绝 junction/symlink 重定向；存在多个候选时需显式选择。工坊目录不会自动执行配套后台。

0.6 工坊一键版将播放器版本放在 `%LOCALAPPDATA%\Zcc\DST-Music\Workshop\3836261433` 下，并为不同版本传入同一个 `-StateDir`（该目录的 `.state`）：连接、启动、停止和原生播放器均使用该状态目录。旧手动版目录不自动迁移或覆盖；首次切换可能需要重新登录。自启动仅经用户在设置中勾选保存后写入当前用户 HKCU Run，默认关闭。工坊启动器及升级回滚仍需最终包与真实订阅环境验收。

一个HUD拥有一个Controller，独立于全屏面板轮询。关闭面板保留歌词/卡片/音乐；退出HUD取消轮询、环境采样、按键和回调引用。Lua明确加载connection文件，不依赖没有返回值的modimport。

字形图集使用独立的单曲资源租约：Controller 加载后将租约交给歌词组件；换歌或组件销毁时先销毁旧字形图片，再卸载图集。不会把每首歌的 RGBA 字库永久留在封面缓存中。

测试使用隔离mock；真实登录由用户扫码，不把mock测试当作账号或游戏画面验收。
