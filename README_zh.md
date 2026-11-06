# AVD MenuBar

[English](README.md) | 简体中文

一个原生 macOS 菜单栏工具，用于管理本机 Android 虚拟设备（AVD），也可预览通过 ADB 连接的 Android 设备。

![AVD MenuBar 演示：菜单栏设备面板与主窗口预览](docs/demo-zh.gif)

[环境要求](#环境要求) · [构建与运行](#构建与运行) · [贡献](CONTRIBUTING.md)

## 功能

- 设备按运行状态分组，显示 Android 版本与 API 级别。
- 启动、关机、重启、冷启动、清除数据、删除、重命名。
- 实时预览，支持触摸和返回/桌面/任务列表/电源/音量按键。
- 命名快照：保存、加载、删除。
- 复制设备信息或启动命令，打开 AVD 目录或模拟器日志。
- 开发工具：adb shell、logcat、截图、Android Studio。
- 创建、重命名、移动 AVD。
- 面板与常用 AVD 可置顶；可选登录时启动。

## 环境要求

- macOS 14 或更新版本。
- Android SDK Command-line Tools、Android Emulator 和 Platform-Tools。
- `avdmanager` 需要 JDK 17 或更新版本。

## 构建与运行

```bash
./scripts/build-app.sh
open build/AVDMenuBar.app
```

产物为 ad-hoc 签名的 `build/AVDMenuBar.app`。GitHub Actions 会为每次推送构建 Apple Silicon 版本，推送版本标签时发布 DMG，见 [Releases](https://github.com/calvingit/AVDMenuBar/releases)。

首次启动时，macOS 可能请求访问 Android SDK 或可移除卷宗；授权后才能读取和操作 AVD。应用只驻留菜单栏。

## 设置

- **工具路径**：自动探测，也可手动指定 avdmanager / emulator / adb。
- **语言**：跟随系统、简体中文或 English，重开应用后生效。
- **外观**：跟随系统、浅色或深色。
- **登录时自动启动**。

## 说明

- 删除 AVD 和清除数据都会二次确认。
- 清除数据会把旧快照保留为 `snapshots.pre-wipe-<时间>`。
- 预览使用 ADB 视频流；视频流不可用时自动降级为截屏。
- 只展示命名快照；保存和加载需要模拟器处于运行状态。
- 模拟器日志位于 `~/Library/Logs/AVDMenuBar/<AVD 名>.log`。

## 项目文档

- [开发约定](AGENTS.md)
- [贡献指南](CONTRIBUTING.md)
- [变更记录](CHANGELOG.md)
- [安全问题报告](SECURITY.md)

## 许可证

计划采用 MIT 许可证。版权主体待确认，正式许可证尚未添加。
