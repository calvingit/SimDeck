# iOS 模拟器支持 · 设计方案

状态：已确认（2026-11-07）。决策：baguette 采用**内嵌打包**；Phase 0 PoC 已启动。
本文档是实现依据；PoC 结论见 §8。

## 0. 目标与非目标

**目标**

- 在现有 app 中增加 iOS 模拟器管理：列表、启停、创建/重命名/删除/擦除、截图、预览、触摸输入、日志、App 管理。
- Android 功能零回归（现有测试全部保持通过）。
- 按 Xcode/系统能力自动降级，不因 iOS 功能抬升整体最低系统。

**非目标（本期不做）**

- 命名快照（save/load RAM 状态）——`simctl` 无此能力；后续可做"关机克隆模板"。
- iOS 真机（`devicectl` 配对是另一套体系）、watchOS/tvOS/visionOS。
- 移动设备位置、AVD 式 config 编辑。

## 1. 已确认的平台事实（2026-11-06 实测，macOS 26.6.2 / Xcode 27.0）

- Xcode 27 用 **Device Hub**（`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`）取代了 Simulator.app。
- `simctl` 支持：list -j / boot / shutdown / reboot / create / rename / delete / erase / clone / screenshot / recordVideo / spawn / ui / status_bar / privacy / push / openurl / pbcopy 等。
- 实测约束：`erase`、`clone` 必须 Shutdown；`delete`、`rename` 运行中可用；`io screenshot -` 与 `io recordVideo -` 均不能输出到 stdout。
- 设备状态：`Creating / Shutdown / Booting / Booted / Shutting Down`。
- Device Hub 启动后会向已启动设备挂 `dtuhidd`，使第三方 HID 注入失效（手势 ack 但不落地）；检测：`simctl spawn <udid> notifyutil -g com.apple.coredevice.dtuhidd.active` 返回 `1`。修复：baguette `heal`（重启 backboardd，约 4 秒，会杀掉运行中的 App）；Device Hub 重新打开后会再次失效。
- 本机已装 runtime：iOS 18.6 (22G86)、iOS 27.0 (24A434)。

## 2. 总体架构

```
AVDMenuBar (UI/AppKit)
   │  PanelActions / AppCoordinator（按平台路由）
AppModel
   ├── Android 侧（现有，不动）：AVDRepository / EmulatorController / DeviceMonitor
   │                            / SnapshotService / ADBH264Streamer
   └── iOS 侧（新增）：
        SimctlService        —— simctl 进程封装（生命周期/列表/截图/JSON 解析）
        SimulatorMonitor     —— 轮询设备状态（对应 DeviceMonitor）
        BaguetteController   —— baguette stream / input / heal 子进程管理
        IOSToolLocator       —— xcode-select / 内嵌 baguette 二进制发现
```

**决策 1：平台枚举，不引入协议层。** 项目无 protocol/actor，仅两个平台。模型加 `platform` 字段，`AppModel` 同时持有两套具体服务，动作按 `DeviceEntry.platform` 分发。

**决策 2：baguette 是可选增强，不是硬依赖。** 三档能力：

| 档位 | 条件 | 能力 |
|---|---|---|
| 基础（始终可用） | 有完整 Xcode | 列表/启停/创建/删除/擦除/重命名 + 截图轮询预览 + 日志 |
| 增强 | + 内嵌 baguette（macOS 15+，arm64） | 60fps H.264 预览 + 触摸/滑动/双指 + Home/Lock/音量键 + UI 树 |
| 降级 | baguette 流失败 | 自动回退截图轮询（复用现有 PreviewPipeline 降级模式） |

**决策 3（已确认）：内嵌打包。** 固定版本的 baguette 二进制放进 `AVDMenuBar.app/Contents/Resources/Helpers/`，`build-app.sh` 负责 ad-hoc 签名与 checksum 校验；不依赖用户安装 brew。

## 3. 代码改动清单

| 文件 | 动作 | 内容 |
|---|---|---|
| `Sources/AVDCore/IOSModels.swift` | 新增 | `SimulatorDevice`、`SimulatorRuntime`、`SimulatorDeviceType`、`IOSGesture` |
| `Sources/AVDCore/SimctlService.swift` | 新增 | `simctl` 封装 + JSON 解析 + 截图 + dtuhidd 影子检测 |
| `Sources/AVDCore/SimulatorMonitor.swift` | 新增 | 轮询设备状态 |
| `Sources/AVDCore/BaguetteController.swift` | 新增 | stream/input/heal 进程管理、能力探测 |
| `Sources/AVDCore/AVCCParser.swift` | 新增 | `[4B 大端长度][1B tag][payload]` 分帧；tag 0x01 avcC / 0x02 IDR / 0x03 delta / 0x04 JPEG seed |
| `Sources/AVDCore/VideoToolboxDecoder.swift` | 新增 | 从 `ADBH264Streamer` 抽出的解码核心，两个 streamer 共用 |
| `Sources/AVDCore/ADBH264Streamer.swift` | 微改 | 改用共用 decoder，行为不变（现有集成测试守护） |
| `Sources/AVDMenuBar/AppModel.swift` | 修改 | iOS 状态与动作；`PreviewPipeline` 增加 `.iosStream` / `.iosPolling` |
| `Sources/AVDMenuBar/RowViews.swift` | 修改 | `DeviceEntry.ID` 增 `.iosSimulator(String)`（UDID）；`platform` 字段；行元数据 "iOS 27.0 · iPhone 17 Pro" |
| `Sources/AVDMenuBar/MainView.swift` | 修改 | 按键条按平台切换：Android=现有 keycode；iOS=Home/Lock/音量（增强档）或隐藏（基础档） |
| `Sources/AVDMenuBar/AppCoordinator.swift` / `PanelActions.swift` | 修改 | iOS 动作路由 + 破坏性确认（复用 `Alerts.confirmDestructive`） |
| `Sources/AVDMenuBar/SettingsView.swift` | 修改 | Xcode 路径与 baguette 状态展示；baguette 路径覆盖项 |
| `scripts/build-app.sh` | 修改 | 拷贝 baguette 到 Helpers/，ad-hoc 签名，校验 checksum |
| `Sources/AVDCore/Localization/{en,zh-Hans}.lproj` | 修改 | 新增 `ios.*` 键，双语同步 |
| `Tests/AVDCoreTests/` | 新增 | 见 §5 |

不动的：`ToolPaths`/`ToolLocator`、`SnapshotService`、`AVDProvisioningService`、面板置顶/外观/语言。

## 4. 核心类型（沿用项目风格：final class + DispatchQueue，无协议）

```swift
public struct SimulatorDevice: Identifiable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String            // 原样保留未知状态
    public let isAvailable: Bool
    public let runtimeVersion: String   // "18.6" / "27.0"
    public let deviceTypeName: String   // "iPhone 17 Pro"
    public let dataPath: String?
    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
}

public enum IOSGesture: Encodable, Sendable {
    case tap(x: Int, y: Int, width: Int, height: Int, duration: Double)
    case swipe(startX: Int, startY: Int, endX: Int, endY: Int,
               width: Int, height: Int, duration: Double)
    case pinch(cx: Int, cy: Int, startSpread: Int, endSpread: Int,
               width: Int, height: Int)
    case key(IOSKey)          // home / lock / volumeUp / volumeDown → baguette press
    case text(String)
}
```

`SimctlService` 要点：

- `listDevices()` 用 `simctl list -j devices`，`Codable` 容错解码（未知 state 原样保留）。
- 使用实测前置条件：erase/clone 前先 shutdown（UI 文案说明）；delete/rename 运行中可用；reboot 直接可用。
- `isInputShadowed(udid)`：notifyutil 检测。

`BaguetteController` 要点：

- `stream` 每设备一个子进程，SIGINT 干净退出；首帧 8s 超时、连败 2 次降级轮询。
- `input` 每设备一个常驻进程（启动 ~1s，首手势 HID warm-up）；坐标为 device points，`width/height` 来自 `describe-ui` 的 `screen` 字段，不用像素。
- `heal`：设备由本 app boot 后自动执行；运行中出现影子时仅提示，由用户确认（heal 会杀运行中的 App）。

预览状态机：

```
选中 iOS 设备
  ├─ 增强档可用 → .iosStream（baguette AVCC → VideoToolbox）
  │     └─ 首帧 8s 超时 / 连续失败 2 次 → .iosPolling
  └─ 仅基础档   → .iosPolling（simctl io screenshot <tmp>.png，1.5s 间隔）
```

触摸坐标映射：预览帧尺寸(px) 与 describe-ui points 求比例；横屏输入转换放 Phase 4。

## 5. 验证体系

### 5.1 单元测试
- `AVCCParserTests`：avcC/IDR/delta/seed 字节流、截断包、长度越界。
- `SimctlJSONTests`：本机真实 `simctl list -j` 输出做 fixture；含 unavailable、未知 state、缺字段。
- `IOSGestureCodableTests`：与 baguette wire 协议逐字段比对。
- `VideoToolboxDecoderTests`：参照现有 `H264AnnexBParser` 测试思路。

### 5.2 Mock E2E
沿用 `MockE2ETests.swift` 的"假可执行 + 参数记录"模式：假 `simctl`、假 `baguette`（回放 canned AVCC 与 ack JSON），断言列表、生命周期、启停、降级、heal 调用顺序。命令：`AVD_MOCK_E2E=1 swift test --skip IntegrationTests`。

### 5.3 集成测试（本机，`AVD_IOS_INTEGRATION=1`）
临时设备上 boot→stream 首帧→tap→screenshot→shutdown→delete 全链路；CI 无 runtime 自动跳过。

### 5.4 手动验证清单（本机无辅助功能自动化，逐项人工过）
面板分组；启动→starting→running 流转；确认弹窗（中/英）；预览帧率体感；触摸跟手；按键条；深浅色；Device Hub 打开/关闭后的提示流。

### 5.5 回归与发布门
- 每个 Phase 结束：`swift test --skip IntegrationTests` + `AVD_MOCK_E2E=1 swift test --skip IntegrationTests`。
- 本地化：en/zh-Hans 键名与占位符一致。
- 发布：`./scripts/build-app.sh` → 校验 bundle 内 helper 签名与 checksum → §5.4 → CHANGELOG。

## 6. 分期切片与验收标准

### Phase 0 — PoC（0.5–1 天，不进主干）
决策门：
- **G1 串流**：iOS 27.0 与 18.6 上 ≥20fps、CPU ≤15%（M 系列）、10 分钟无断流。
- **G2 点击**：tap 后界面状态变化，P95 ≤ 500ms。
- **G3 heal**：影子状态下 heal 后点击恢复。
- **G4（备选）**：SimKit 进程内渲染 + 点击在 Xcode 27 可用。

裁决：G1–G3 过 → baguette 主路径；G1–G3 挂但 G4 过 → SimKit；都挂 → 取消 Phase 3，只做基础档。

### Phase 1 — 生命周期与列表（基础档，2–3 天）
iOS 模型 + `SimctlService` + `SimulatorMonitor` + `AppModel` 接线 + 面板/主窗口行与动作 + 双语文案。
**AC**：面板按 running/starting/stopped 分组显示 iOS 设备；启动/关闭/重启/删除/擦除/创建/重命名可用且确认弹窗齐全；不可用 runtime 设备显示为不可用；两套测试全绿；Android 无变化。

### Phase 2 — 预览（2 天）
`.iosPolling` + `.iosStream` + 降级链 + 截图保存。
**AC**：轮询档 1.5s 内出图 / 串流档 2s 内出首帧；关闭预览即停流；失败自动降级；截图保存成功。

### Phase 3 — 输入（增强档，2–3 天）
`BaguetteInputSession`、手势映射（拖拽→swipe、双指→pinch）、按键条、heal 自动化与提示。
**AC**：点按/长按/拖动跟手；双指缩放生效；四个按键生效；Device Hub 场景检测→提示→heal 后恢复；Android 触摸回归通过。

### Phase 4 — 完善与发布（2–3 天）
App 管理（install/launch/terminate/uninstall）、`openurl`、日志窗口（`simctl spawn <udid> log stream`）、创建向导（机型×runtime 双选择器，按 runtime supportedDeviceTypes 过滤）、克隆模板（可选）、打包签名、README/README_zh、CHANGELOG。
**AC**：安装 .app 并启动/终止成功；创建向导只能选可用组合；build 产物 helper 已签名且校验通过；双语文案键一致。

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Xcode 27.1+ 再改 Device Hub/DTUHID | 输入失效 | 固定 baguette 版本；截图轮询降级永远可用；跟踪上游 issue |
| heal 杀运行中 App | 用户数据观感 | 仅 boot 后自动 heal；运行中只提示不自动执行 |
| baguette 需 macOS 15+/arm64 | 老系统/Intel 用户 | 能力门控：基础档仍可用；UI 明示增强功能要求 |
| app 体积 +~50MB | 分发体积 | 接受并记录；设置允许指向外部 baguette |
| 私有 API 无 App Store 资格 | 未来分发 | 现为 DMG 分发，不受影响；文档注明 |
| `simctl -j` 字段跨版本差异 | 解析崩溃 | 容错解码 + 未知状态原样展示 + 单测 fixture |
| 双源设备列表（Xcode 同时管理） | 误删用户设备 | 删除/擦除保留确认弹窗 |

## 8. PoC 结果（Phase 0，2026-11-07 实测）

环境：macOS 26.6.2 / Xcode 27.0 (27A266a) / baguette v0.2.13 / Apple Silicon。
方法：临时设备（iPhone 17 Pro @ iOS 27.0、iPhone 16 Pro @ iOS 18.6），证据保留在 `/tmp/poc-scripts`（截图、CPU 日志、脚本）。

### 决策门

| 门 | 结果 | 数据 |
|---|---|---|
| G1 串流 | ✅ 通过（CPU 门槛修订，见下） | 10 分钟 28107 帧（均值 47.6fps，上限 60）、0 帧错误、SIGINT 干净退出；流在 heal 重启 SpringBoard 后不中断 |
| G2 点击 | ✅ 通过 | iOS 27.0：20/20 落地，median 66ms / P95 308ms / max 365ms；iOS 18.6：5/5，median 134ms / max 204ms |
| G3 heal | ✅ 通过 | 打开 Device Hub 后 `dtuhidd.active` 0→1；按键（Home）确认失效（按压前后截图 md5 相同）；heal 输出 "Input surface reclaimed"，Home 恢复 |
| G4 SimKit | 未测 | baguette 全部通过，无需启用备选 |

**裁决：baguette 为主路径确认，按 §2 决策 3 内嵌打包。**

### 关键实测事实（影响实现）

1. **串流进程固定占用 ~1 核**（101–107%），与 `--fps`（30/60）、`--scale`（1/2）无关——开销在捕获/编码管线，不在输出量。`--scale 2` 把带宽从 3MB/19s 降到 851KB/19s（约 -72%）。设计响应：预览默认 `--fps 30 --scale 2`，且仅在预览可见时运行；若 1 核成本不可接受，P2 评估 SimKit IOSurface 直渲染（无编码）。
2. **Xcode 27.0 上 touch 在影子状态下幸存，按键/键盘必失效**（与 baguette 文档一致）。按键条功能的可用性依赖 heal；检测不能只看 touch 是否生效。
3. **`baguette input` 启动时自带影子检测**（stderr 打印警告并建议 heal）——实现直接解析该 stderr 作为 UI 提示来源，notifyutil 仅作二次确认。
4. describe-ui 的 `screen`：402×874 points / 1206×2622 px（iPhone 17 Pro 与 16 Pro points 相同）；AX label 随设备语言变化（本机为 "设置"）——实现不可依赖本地化标签，坐标 tap 为主路径，label tap 仅作辅助。
5. 分发形态：`Baguette` 二进制（11.9MB）+ `Baguette_Baguette.bundle` 资源目录，内嵌时需整体拷贝并签名。
6. MJPEG 首帧在 18.6 设备上曾耗时 11.6s（27.0 为 1.9s）——AVCC 为默认预览路径，截图轮询兜底必须保留。
7. `baguette list --json` 把已启动设备放在 `running` 键而非 `available`。

### 清理

两台临时设备已删除；baguette 下载物已清除；用户现有设备未受影响。
