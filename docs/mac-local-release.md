# VoiceStudio Mac 本地发布

本机项目：`/Users/tao/Developer/Fireseed/shengyin`。入口：`python3 scripts/local-ios-release.py`。
默认 dry-run；即使传入版本号也不会上传、分配或占用 App Store Connect 构建号。

```sh
python3 scripts/local-ios-release.py --dry-run
# 执行完整本地验证、Archive、导出及 IPA preflight；仍然不上传。
python3 scripts/local-ios-release.py --execute --version 0.1 --build-number 1
```

本地验证可保留工程的 0.1 (1)。这不证明 1 或任何其他编号可上传。未来发布前须在 ASC 核对未使用的编号，包括 processing/failed 历史，不能根据仓库值或上次 Build 6 推断可用编号。

执行环境需要 Xcode、已安装 iPhone Simulator runtime、Git、CMake、Python 3、Node/npm、既有 Apple Distribution 私钥和 VoiceStudio 专用 profile。模型放在被忽略的 `local-models/OpenVoiceV2`。脚本选择首个名称以 iPhone 开头的可用模拟器，，也可通过 `--simulator-id <UDID>` 明确指定验收设备；脚本验证/复用字节完全一致的 fixture；不同的既存 fixture 会阻塞，不自动覆盖。

顺序为 Core（严格并发）、Node、Python、固定 CPU runtime、Debug、真实 OpenVoice fixture、完整 App XCTest/UI、固定 device runtime、Release、ORT MinimumOSVersion 对齐、签名 Archive、Archive 验证、exportArchive、IPA 验证。Xcode 27.1 测试后 verbose sysdiagnose 收集出现挂起，因此使用 `-collect-test-diagnostics never`，保留普通测试日志/xcresult；这不改变测试范围或断言。任何失败立即停止，原始日志与 `result.json` 留在新的 `local-releases/<时间>/`。输出目录已存在时拒绝运行；脚本不编辑工程版本号。

## 固定签名和资源

- Team：`Z36ZADH7T7`
- Bundle：`com.fireseed.voicestudio`
- ASC App ID：`6816751639`
- Identity SHA-1：`F0B896DA427C62C17DDFFFE84F6B08A57A5E159D`
- Profile：`Voice Studio App Store Distribution`
- Profile UUID：`fa3f93de-933a-493c-be0a-3e85c0a66c69`
- Profile 到期：2027-09-27 23:59:20 UTC

脚本固定现有身份，不使用 automatic provisioning，不带 `-allowProvisioningUpdates`，不创建、导入或撤销证书。若以后资产轮换，先核验并明确更新脚本的固定身份，不自动选择其他证书。不复用其他 App 的 profile 或环境参数。

Archive 和导出 App 都要检查真实签名、证书与 profile 的匹配、Team、Bundle、entitlements、版本、build、MinimumOSVersion、iPhone family、AppIcon、embedded frameworks 和 Mach-O metadata。导出配置固定 `destination=export`，关闭自动管理版本号；导出本身不会上传。

## Xcode 27.1 构建兼容

Kitten SDK 保持 0.1.0 / `4da0abbb92af4e7faf61affabbdb80d334ea768e`，ORT 保持 1.24.2 / `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`。
`prepare-local-kitten-package.py` 验证原提交和原 manifest 后，仅在 DerivedData 的 SPM checkout 中把 `.unsafeFlags(["-std=c++17"])` 改成标准 `cxxLanguageStandard: .cxx17`。它不编辑依赖 target 源码，不替换版本，不关闭 SwiftPM 安全校验；遇到未识别 manifest 改动即停止。SPM 缓存重建后要重新执行该步骤，发布入口已包含。

`VoiceStudioHome` 仅提取原 Generate 卡片/按钮表达式为计算属性，规避 Swift 6.4 类型检查超时；原交互和状态条件保持。不得通过降低测试要求规避编译或测试失败。

流程参考 AIQuickNote 的本地 Archive/export 命令方案，并沿用本项目已成功的 TestFlight workflow 中的 ORT 对齐及二进制 preflight。AIQuickNote 的本地准备文档本身不是其本地上传成功证据。

## 未来获准上传时

MIG-MAC-02 禁止上传。以下是未来独立授权后的门禁说明，本阶段不执行。

CLI 上传还需要既有 `API_KEY_ID`、`API_ISSUER_ID`、`API_PRIVATE_KEY_BASE64` 凭据，经安全的仓库外方式提供。不要把 P8/密码贴进聊天、脚本参数、Git 或日志。脚本只在上传时把 Key 临时放入权限受限的目录，退出后删除临时副本；不修改用户原 Key。

未来运行需同时指定 `--execute --upload --confirmed-unused-build`，以及精确的 `--upload-authorization 'UPLOAD com.fireseed.voicestudio VERSION (BUILD)'`。该参数表示操作者已经获得本次明确上传授权，不能由 agent 自行补填以推导授权。保留默认不上传，不提供跳过测试的选项。

上传后查询现有 App 的 Apple processing 状态，只有 `VALID` 才记录成功。`uploaded=true` 但处理失败/查询超时不算发布成功，应保留日志并继续核实该编号，不能盲目重传。Organizer 账号可用于未来人工上传，但不能代替本脚本所需的 API 凭据。

签名若卡住：先执行最小副本签名验证，检查实际进程和日志；确认挂起进程已终止、保留原输出后才在新目录受控 `-jobs 1` 重试。不通过重建证书解决。

本次完整通过基线的模拟器为 `D2B8AFD6-E1A3-4EA1-91C7-7274575F2BAF`（iPhone17/iOS27.0）。未来本地重现可传 `--simulator-id D2B8AFD6-E1A3-4EA1-91C7-7274575F2BAF`；未指定时仍用 CI 的首个 iPhone 选择逻辑，当前可能选到尚有两项 UI 失败的 Duo/iOS27.1。切换设备不等于修复该失败，详见 MIG-MAC-02 验收报告。

Archive 不全局覆盖 CODE_SIGN_IDENTITY，以免与 Swift Package 的自动签名静态目标冲突；App target 继续使用工程内既有手动 Apple Distribution 配置和专用 profile。导出和实际签名叶证书校验固定本次验证的 identity SHA-1。
