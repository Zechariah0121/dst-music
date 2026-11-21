name = "本机音乐播放器（网易云 / QQ 测试版）"
description = "Windows 客户端测试版。首次在工坊目录双击“一键启动播放器.cmd”，首次可选择安装位置，自动解压并连接；进游戏后可从 ESC→音乐播放器进入设置或连接页，无需退出世界。支持网易云 / QQ 音源切换、歌单、搜索、悬浮歌词与环境音效；左上音乐按钮可隐藏，关闭游戏自动暂停。自启动为可选项、默认关闭。朋友无需安装，请勿同时启用旧本地版。"
author = "Zcc"
version = "0.6.0-beta.6"
icon_atlas = "modicon.xml"
icon = "modicon.tex"
api_version = 10
dst_compatible = true
client_only_mod = true
all_clients_require_mod = false
configuration_options = {
    {
        name = "toggle_key",
        label = "音乐面板快捷键",
        options = {
            { description = "F6", data = "KEY_F6" },
            { description = "F7", data = "KEY_F7" },
            { description = "F8", data = "KEY_F8" },
            { description = "F9", data = "KEY_F9" },
            { description = "关闭快捷键", data = false },
        },
        default = "KEY_F8",
    },
}
