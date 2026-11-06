# 贡献指南

欢迎报告问题、改进文档或提交代码。若要改变设备操作、数据安全或系统权限相关行为，请先和维护者确认预期。

## 本地开发

需要 macOS 14 或更新版本，以及支持 Swift 5.9 或更新版本的 Xcode 工具链。构建和模拟工具测试不需要 Android SDK；运行应用的 AVD 功能时，请按 [README](README.md#环境要求) 准备 SDK。

```bash
swift build
swift test --skip IntegrationTests
AVD_MOCK_E2E=1 swift test --skip IntegrationTests
```

涉及菜单栏、预览、设置或资源打包时，用 `./scripts/build-app.sh` 生成应用，并在 macOS 上手动验证相关操作。若改了文案，至少检查简体中文和英文，确认长文案未被截断、占位符值显示正确。

真实 SDK 和设备测试请单独运行。H.264 测试会在检测到的设备上启动短时录屏，建议只连接专用测试设备：

```bash
AVD_INTEGRATION=1 swift test --filter IntegrationTests
```

## 报告问题与提交改动

- 报告问题时，提供应用版本或构建来源、macOS 版本、设备类型、复现步骤，以及预期和实际行为。仅附相关日志片段，先去掉设备序列号、用户名、本机路径和其他敏感信息。
- 提交改动时，说明解决的问题、用户可见变化、验证命令和未覆盖的场景。涉及启动、关机、快照或清除数据时，明确列出行为变化。
- 安全问题按 [SECURITY.md](SECURITY.md) 私下报告。
