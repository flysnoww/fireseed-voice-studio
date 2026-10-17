# MIG-MAC-02 — Mac 本地恢复与发布准备验收

日期：2026-10-17（America/Los_Angeles）。项目目录：`/Users/tao/Developer/Fireseed/shengyin`。
总体结论：**BLOCKED**。本地恢复、构建、签名、Archive/IPA 验证已完成；iPhone Duo / iOS 27.1 的两个 UI 失败和无人值守上传配置仍未解决。

| 阶段 | 状态 | 结果 |
| --- | --- | --- |
| M1 | PASS | ZIP/7z SHA-256、ZIP 完整性、路径安全、文件清单匹配 |
| M2 | PASS | Git HEAD 与远端 main、迁出版本一致 |
| M3 | PASS | OpenVoice/历史音频/归档资料哈希匹配 |
| M4 | BLOCKED | iPhone17/iOS27.0 全基线通过；Duo/iOS27.1 两项 UI 失败未解决 |
| M5 | PASS | 现有 Distribution 私钥身份和 VoiceStudio profile 匹配 |
| M6 | PASS | 基于完整通过基线生成本地 Archive/IPA，全部 preflight 通过 |
| M7 | PASS | 发布入口、默认 dry-run、上传门禁及测试完成；真实上传 NOT RUN |
| M8 | PASS | Mac/Windows/MacBook/GitHub 角色及本地发布规范已更新 |
| M9 | PASS | 本报告与本地 result.json 已生成；整体阻塞如实保留 |

本次没有上传 TestFlight，没有创建/撤销证书，没有合并历史研究补丁，没有改变业务功能。
本地原始证据保存在被 Git 忽略的 `migration/MIG-MAC-02/`；模型在被忽略的 `local-models/`。没有提交或推送本次改动。

## M1 — PASS：迁移包

- ZIP：123,485,519 bytes；107 个成员，CRC/完整解压通过，106 条清单 SHA-256 全部通过。
- ZIP SHA-256：`a1d9e9632d8f34d13aab2e814bdce6e04eb38804070717173a0909b8482a5994`。
- 拒绝绝对路径、父目录穿越、反斜杠/驱动器路径、符号链接、重复和大小写冲突路径；仅解压到新建的独立 staging 目录，没有覆盖 checkout。
- Secure 7z：8,635 bytes；SHA-256 `0c2af3c3e0a13221ae9469e31781e1f759603873afae33842aaca9b93da76e56`。本次未解密；它不是含私钥的完整签名身份。
- 阅读了 README、迁出审计、package-validation 和迁移清单；路径按本次用户指定的 `shengyin`，没有采用旧 README 中的另一个项目路径。

## M2 — PASS：Git 源码

原目标目录存在且为空，没有本地修改或旧 Git checkout。克隆 GitHub main 后：

- HEAD / origin/main / 远端 main：`23191571cc194758c3d889d3f05927288cb8e3ce`。
- 没有远端新增提交。原始源码恢复一致；后续变更仅为本地构建兼容、发布工具、规范与文档，详见下文。
- 没有将迁移历史源码、Qwen 历史 patch 覆盖或合并到 main。

## M3 — PASS：本地资源

- OpenVoice V2：7 files / 66,026,274 bytes；恢复到 `local-models/OpenVoiceV2`，所有文件 SHA-256 匹配；LICENSE 一并保留。
- 历史 WAV：45 files / 66,929,948 bytes；保留于 `migration/MIG-MAC-02/verified-package/transfer/fixtures/history`，全部校验通过，不混入当前测试或 Git。
- 历史未跟踪源码 23 项及 Qwen 配置/补丁快照保留于 verified-package 的 `transfer/local-source` / `transfer/configs/qwen-history`。原 ZIP 保留，没有自动合并。
- 已恢复文件逐项哈希见 `restored-files-sha256.json`（106 个 staging 清单文件，加 8 个本地模型/许可证文件）。
- 当前 iOS 测试自行生成所需测试音频；真实转换 UI fixture 使用迁移 OpenVoice pack，经字节校验后安装到模拟器 Documents/UIOpenVoicePack。
- CoreML 使用上述模型；ONNX Runtime 从已锁定的 SPM 1.24.2 依赖恢复。没有恢复/下载 Qwen 大型权重，没有上传模型。Tiny/Kitten 离线首次使用权重不在迁移包中，本次未补充；编译和本次测试不依赖它们。

## M4 — BLOCKED：默认设备组合；完整基线 PASS

| 本地检查 | 数量/结果 |
| --- | --- |
| Core（严格并发） | PASS，30 |
| App XCTest | PASS，66 |
| UI 完整基线（iPhone 17 / iOS 27.0） | PASS，7；xcresult 确认 App/UI 共73通过，0失败，0跳过 |
| Node | PASS，7 |
| Python | PASS，13（原7 + 发布门禁5 + processing鉴权刷新1） |
| 唯一基线测试合计 | 123通过，0失败，0跳过 |
| Debug Simulator build | PASS |
| Release iPhone build | PASS |

首次按 CI 首个 iPhone 选择逻辑使用 iPhone Duo / iOS 27.1，UI 为5通过、2失败：

- `testSavedVoiceShapingAutomaticConversionAndAudioObjectCard`：调节 Speed 后无法找到 Pitch Slider（原测试第110行）。
- `testShapedPreviewNeedsNoHomeTextAndDoesNotCreateHistory`：调节 Speed 后无法找到 previewShapedVoiceButton（tap helper 第16行）。

未修改、删除或跳过任何测试。两个用例在新建的 iPhone17/iOS27.0 上原样诊断通过，再执行全部66+7项并完整通过。设备和 runtime 同时变化，现有证据只能定位到环境组合差异，不能确定具体根因，也不能声称 Duo27.1 已修复；因此 M4 保留 BLOCKED。

原 Xcode 进程在测试后诊断收集阶段挂起，发送 SIGINT 未退出，随后仅终止本任务两个挂起进程。首次/诊断重试 xcresult 未完成封存，原日志和原始数据保留。全套基线使用 Xcode 支持的 `-collect-test-diagnostics never` 关闭可选 verbose sysdiagnose，保留普通日志和 xcresult；最终退出成功，FullBaselineTests.xcresult 可被 xcresulttool 读取。这没有改变测试范围、断言或通过条件。

完整结果同时记录已有 AVAudioSession 主线程激活、无效 frame 等 runtime warnings；本阶段不做业务修复。

环境：Xcode 27.1 (27A9275)、Swift/SPM 6.4、iOS 27.1 Simulator (iPhone Duo，初次) / iOS 27.0 (iPhone 17，完整基线)、Git 2.54.0、gh 2.102.0、Codex CLI 0.163.0-alpha.10.2、Node 24.22.0/npm 11.19.1、Python 3.9.6。复用了已有安装；缺少 CMake，经安装后为 4.4.4。

同一 HEAD 历史 GitHub Actions：iOS CI `37238262683`、Internal Test Package `37238262681`、TestFlight `37259638376` 均成功。历史 iOS CI 使用 Xcode 26.6，Core 30 / App XCTest 66 / UI 7 通过。本次只读读取了历史日志，没有触发新 workflow。

必要的构建兼容变更：

1. Kitten 0.1.0 / `4da0abbb92af4e7faf61affabbdb80d334ea768e` 的原 manifest 使用 unsafe C++17 flag，被 Xcode 27.1 阻止。改为同一 SHA 引用仍失败，已撤回该尝试。最终只在 SPM 派生 checkout 将该参数转换为 `cxxLanguageStandard: .cxx17`；版本、依赖 target 源码不变，不关闭安全校验。脚本记录原/修改 manifest 哈希并拒绝未知改动。
2. Swift 6.4 对原大型 SwiftUI 表达式类型检查超时。将 Generate 卡片和按钮原样提取为两个计算视图属性。展开后与原 HEAD 忽略空白逐字符一致；没有修改控件、条件、回调或业务逻辑。完整 App/UI 回归用于验证行为。
3. ORT 仍为 1.24.2 / `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`。没有升级依赖或削弱测试。

## M5 — PASS：现有 Distribution 签名

沙箱内最初看到零身份；经真实钥匙串只读复核，已存在有效身份和私钥：

- `Apple Distribution: Tao Wu (Z36ZADH7T7)`。
- SHA-1：`F0B896DA427C62C17DDFFFE84F6B08A57A5E159D`。
- 证书 SHA-256：`387522485469480502186b2aef1ddb35a66489a4c850242a4ace1e5f5005736c`。
- 证书有效至 2027-09-27 23:59:20 UTC；最小副本 codesign 及 strict verify 通过。
- Mac 原来只有 AIQuickNote profile；没有复用它。确认缺少 VoiceStudio profile 后，从迁移资产中现有明文公共恢复文件安装，无需解密备用 7z。
- Profile：Voice Studio App Store Distribution；UUID `fa3f93de-933a-493c-be0a-3e85c0a66c69`。
- Team `Z36ZADH7T7`、application identifier `Z36ZADH7T7.com.fireseed.voicestudio`、get-task-allow=false、非设备限定，且 DeveloperCertificates 与现有身份匹配。
- Profile 有效至 2027-09-27 23:59:20 UTC。
- 原/已安装 profile SHA-256：`4e0271198a38b4b0f0ca7b312ba9c6a5c4dc9fd3f76ddb9c5c1437a1b84e9c84`，安装后再次验证一致。

## M6 — PASS：本地验证 Archive 与导出 IPA

完整 iPhone17/iOS27.0 基线和签名验证通过后生成：

- Archive：`migration/MIG-MAC-02/VoiceStudio.xcarchive`。
- IPA：`migration/MIG-MAC-02/export/VoiceStudio.ipa`；11,208,704 bytes。
- IPA SHA-256：`6afbc952df4d2aff4ea55a7abe956ee4eccc3aebfada51bc49e12d2342b6b4e5`。
- Bundle ID：`com.fireseed.voicestudio`；Team：`Z36ZADH7T7`。
- 实际签名：Apple Distribution: Tao Wu (Z36ZADH7T7)，叶证书与指定 profile 的 DeveloperCertificates 字节匹配。
- Profile：Voice Studio App Store Distribution / `fa3f93de-933a-493c-be0a-3e85c0a66c69`。
- Version / Build：`0.1 (1)`；没有改变工程版本，没有上传或占用新发布编号。
- MinimumOSVersion：17.0。
- Embedded framework：onnxruntime.framework；arm64、IOS、Mach-O minOS17.0，wrapper plist17.0一致；ORT源码锁定1.24.2。
- Entitlements：application-identifier=Z36ZADH7T7.com.fireseed.voicestudio、team-identifier=Z36ZADH7T7、get-task-allow=false、beta-reports-active=true。
- Archive/IPA 的 strict/deep codesign、叶证书/profile、AppIcon、iPhone family、版本号、entitlements、嵌入二进制兼容性均 PASS。

第一次 Archive 的全局 CODE_SIGN_IDENTITY 覆盖造成自动签名 Swift Package 静态目标冲突，未生成有效 Archive。改为本项目历史成功做法：不全局覆盖 identity，保留 App target 原有手动 Apple Distribution 配置及指定 VoiceStudio profile；导出与实际证书核对仍固定现有身份。重试成功，不改工程签名配置、不新建证书。验证脚本首次执行还发现 codesign 可选参数需要 `--extract-certificates=prefix` 形式，修正后对实际 Archive/IPA 验证通过。全部失败/重试日志保留。

此产物仅作本地签名/打包验证，不表示 Duo27.1 已通过，也不表示已具备上传条件。

仅本地验证，保持版本 0.1、构建号 1；不写工程版本号，不占用 ASC 发布编号。完整测试通过后才允许 Archive。签名预检已经通过；不创建或撤销任何证书。

## M7 — PASS：发布脚本准备；真实上传 NOT RUN

入口：`scripts/local-ios-release.py`。用法：`docs/mac-local-release.md`。

自动执行 Core/Node/Python、Debug、全部 App/UI、Release、Archive、签名检查、exportArchive 和 IPA preflight。默认 dry-run，执行本地流程也不上传；输出使用全新目录，保存日志、构建号、最终结果。明确授权、确认未使用构建号及 API 配置三者齐全才允许未来上传；上传后检查 Apple processing=VALID。

复用 AIQuickNote Archive/export 方案及本项目历史成功的 TestFlight workflow 命令和 ORT preflight。没有复用 AIQuickNote 的 Bundle/profile/环境参数；AIQuickNote 准备文档本身未作为其本地上传成功证据。

新增上传门禁/防覆盖测试 5 项、processing JWT 刷新测试 1 项；保留原 Python 7 项。修复原 ingestion 工具在长处理等待期间 JWT 超过 15 分钟有效期的问题。该测试使用假 Key 和模拟 API；日志中的 VALID 是单元测试结果，不是本次 Apple 上传状态。

Dry-run 和所有门禁测试已执行。完整发布入口尚未从头重复执行；本次验收按同一阶段命令分别执行并保存原始证据。真实上传分支、真实 Apple processing 查询均未运行。

## M8 — PASS：开发规范

AGENTS.md 已改为 Mac Studio 主 iOS 开发/测试/发布，Windows RTX 5070 Ti 主 GPU 实验与协作，MacBook Pro 移动/备用，GitHub 源码同步/备份/备用 CI。保留业务、安全和测试要求；闭环 CI 规则仅适用于明确要求远端 CI 的任务，本地日常 TestFlight 不再强制依赖 Actions。

## M9 — PASS：报告完成；发布条件仍 BLOCKED

结果汇总：`migration/MIG-MAC-02/result.json`。基线完整测试、Archive/IPA preflight 和 SHA-256 结果均保留。

尚存阻塞：

1. iPhone Duo / iOS27.1 上两个 UI 失败仍未解决。不能用 iPhone17/iOS27.0 的通过结果声称该组合已修复。
2. 本机未配置本地 CLI 无人值守上传所需的既有 API Key/Issuer/P8。
3. 未来可上传的未使用构建号没有实时确认。

结论：**尚不具备可直接自动 TestFlight 发布的条件**。本地构建/签名/导出链路已验证；不把凭据、设备组合回归和构建号门禁视为已解决。

无人值守自动 TestFlight 上传仍 BLOCKED：本机标准位置和当前环境未配置 App Store Connect API Key/Issuer/P8；未来的可上传构建号也未实时确认。本阶段禁止上传，因此没有要求迁移 P8、没有查询新构建状态，也没有测试上传分支。ASC App ID 为 `6816751639`。

上传 TestFlight：NOT RUN。Apple processing 实时查询：NOT RUN。新功能开发：NOT RUN。

本阶段结束后 STOP，等待用户确认；不自动发布或进入新功能。
