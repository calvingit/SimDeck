# AVD MenuBar 开发约定

用中文沟通，先给结论，再给证据和下一步。代码标识符、注释和提交信息沿用现有惯例。保护用户已有改动，只修改任务需要的内容；不顺手升级依赖、重构或格式化无关代码。

## 项目入口

- `Sources/AVDMenuBar/`：SwiftUI 界面、AppKit 窗口与菜单栏、状态管理及操作协调。
- `Sources/AVDCore/`：SDK 工具探测、命令执行、AVD 与快照管理、ADB 预览流。
- `Tests/AVDCoreTests/`：核心单元测试、模拟工具测试和真实 SDK／设备测试。
- `scripts/build-app.sh`：用 SwiftPM 构建并打包，产物在 `build/AVDMenuBar.app`；打包会重建该产物。
- [README.md](README.md) 说明用户可见行为；[DECISIONS.md](DECISIONS.md) 记录设计取舍。

## 修改与验证

- 修改用户可见文案时，同步更新 `Sources/AVDCore/Localization` 中的 `en.lproj` 和 `zh-Hans.lproj`，保持键及格式占位符一致。系统权限说明维护在 `Resources/*/InfoPlist.strings`。
- 操作前区分 AVD 名称、ADB 序列号和进程。保留对过期序列号的校验；删除和清除数据等操作仍须确认。
- 日常验证用 `swift test --skip IntegrationTests`；需要验证命令及设备操作时用 `AVD_MOCK_E2E=1 swift test --skip IntegrationTests`。真实设备测试可能启动录屏，按 [CONTRIBUTING.md](CONTRIBUTING.md) 单独运行。
- 涉及界面、签名或资源打包时，按风险运行构建并检查成品。说明实际验证的范围；编译通过不能证明界面或真机行为。
- 交付前检查变更范围。不经明确授权，不推送、重写历史或执行破坏性 Git 操作；删除任务外文件、操作真实设备数据或生产环境、批量跨文件替换、安装或升级依赖前先询问。
