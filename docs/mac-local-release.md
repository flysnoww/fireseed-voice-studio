# VoiceStudio Mac 本地发布

本机项目：`/Users/tao/Developer/Fireseed/shengyin`。入口：`python3 scripts/local-ios-release.py`。
默认 dry-run；即使传入版本号也不会上传、分配或占用 App Store Connect 构建号。

```sh
python3 scripts/local-ios-release.py --dry-run
# 执行完整本地验证、Archive、导出及 IPA preflight；仍然不上传。
python3 scripts/local-ios-release.py --execute --version 0.1 --build-number <明确选择的本地验证编号>
```

执行必须明确给出构建号；默认 dry-run 的 build 为 null，不会自动重置为 1。所有 Xcode 阶段统一使用指定值，Archive/IPA 再检查实际版本。构建号是否可上传须在 ASC 核对所有状态，包括 processing/failed 历史，不能根据仓库值或旧发布记录推断。Build 1 上传禁令继续保留。

执行环境需要 Xcode、已安装 iPhone Simulator runtime、Git、CMake、Python 3、Node/npm、既有 Apple Distribution 私钥和 VoiceStudio 专用 profile。模型放在被忽略的 `local-models/OpenVoiceV2`。脚本选择首个名称以 iPhone 开头的可用模拟器，，也可通过 `--simulator-id <UDID>` 明确指定验收设备；脚本验证/复用字节完全一致的 fixture；不同的既存 fixture 会阻塞，不自动覆盖。

顺序为 Core（严格并发）、Node、Python、固定 CPU runtime、Debug、真实 OpenVoice fixture、完整 App XCTest/UI、固定 device runtime、Release、ORT MinimumOSVersion 对齐、签名 Archive、Archive 验证、exportArchive、IPA 验证。Xcode 27.1 测试后 verbose sysdiagnose 收集出现挂起，因此使用 `-collect-test-diagnostics never`，保留普通测试日志/xcresult；这不改变测试范围或断言。任何失败立即停止，原始日志与 `result.json` 留在新的 `local-releases/<时间>/`。输出目录已存在时拒绝运行；脚本不编辑工程版本号。

Identity V1 的配置、数据备份/认领策略、依赖与测试边界见 [identity-v1.md](identity-v1.md)。App XCTest 加 UI 的本地门禁现为至少 86 项、零失败、零跳过；Debug/Release、Archive 和 IPA 均验证 VoiceStudio 自己的 Native Client、Issuer 和完整回调配置。真实 Apple/Google 与实体 iPhone 的验收另记，不能用 fixture 替代。

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

## Export Compliance 声明

VoiceStudio App target 的 Debug 与 Release 均将 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` 设为 `NO`；本地发布流程分别读取两种构建产物中的最终 `Info.plist`，要求 `ITSAppUsesNonExemptEncryption` 确实是布尔值 `false`。Archive 和导出 IPA preflight 也执行相同检查，缺失、字符串值或 `true` 都会阻断。

声明判断基于本仓库 app target 和锁定依赖的审计：App/Core 中 `CryptoKit` 仅用于 SHA-256 文件完整性校验及缓存键，不实现数据加密、解密、密钥交换或自有加密协议；应用存储走普通本地文件和 `UserDefaults`。KittenTTS Swift 0.1.0（锁定 revision `4da0abbb92af4e7faf61affabbdb80d334ea768e`）通过 Foundation `URLSession` 从 Hugging Face 下载模型，网络传输使用系统 HTTPS/TLS；该包的 Sources 未发现应用层加密实现。ONNX Runtime Swift Package Manager 1.24.2（锁定 revision `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`）作为本地模型推理运行时使用，检查其 Swift bindings 未发现加密/密钥功能。Qwen/OpenVoice 资源在本地加载，SHA-256 用于校验；未发现非 Apple 加密库或其他第三方网络 SDK。因而当前构建仅涉及散列和系统提供的 HTTPS/TLS，满足 Apple 对 `NO` 值的定义（未使用加密或仅使用豁免加密）。如果新增自有加密、非 Apple 加密库、加密 SDK 或改变依赖网络/存储能力，必须重新做出口合规判定后再发布；此布尔值是基于当前版本功能与依赖的申报，不替代法律审查。

Apple 说明该键为 Boolean，`NO` 表示 App 及其第三方库没有加密，或只使用符合豁免条件的加密；操作系统提供的 HTTPS（例如 `URLSession`）通常属于豁免形式。依据：[ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/BundleResources/Information-Property-List/ITSAppUsesNonExemptEncryption)、[Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)。

## Xcode 27.1 构建兼容

Kitten SDK 保持 0.1.0 / `4da0abbb92af4e7faf61affabbdb80d334ea768e`，ORT 保持 1.24.2 / `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`。
`prepare-local-kitten-package.py` 验证原提交和原 manifest 后，仅在 DerivedData 的 SPM checkout 中把 `.unsafeFlags(["-std=c++17"])` 改成标准 `cxxLanguageStandard: .cxx17`。它不编辑依赖 target 源码，不替换版本，不关闭 SwiftPM 安全校验；遇到未识别 manifest 改动即停止。SPM 缓存重建后要重新执行该步骤，发布入口已包含。

`VoiceStudioHome` 仅提取原 Generate 卡片/按钮表达式为计算属性，规避 Swift 6.4 类型检查超时；原交互和状态条件保持。不得通过降低测试要求规避编译或测试失败。

流程参考 AIQuickNote 的本地 Archive/export 命令方案，并沿用本项目已成功的 TestFlight workflow 中的 ORT 对齐及二进制 preflight。AIQuickNote 的本地准备文档本身不是其本地上传成功证据。

## 未来获准上传时

MIG-MAC-02 禁止上传。以下是未来独立授权后的门禁说明，本阶段不执行。

上传默认使用 Xcode Settings → Accounts 中已登录的 Apple 开发者账号。IPA preflight 后，脚本对同一个 Archive 再执行一次 `xcodebuild -exportArchive`，参数为 `method=app-store-connect`、`destination=upload`，并关闭 Xcode 自动管理版本/构建号；不需要 P8。该路径的上传日志保存在 release 输出目录。Xcode 上传成功只确认 Apple 接收，`result.json` 会保留 `PENDING_ASC_CONFIRMATION`，不表示处理完成或已可安装。

无人值守 API Key 路径仍可通过 `--upload-mode api-key` 选择，需要既有 `API_KEY_ID`、`API_ISSUER_ID`、`API_PRIVATE_KEY_BASE64` 凭据，经安全的仓库外方式提供。不要把 P8/密码贴进聊天、脚本参数、Git 或日志。脚本只在上传时把 Key 临时放入权限受限的目录，退出后删除临时副本；不修改用户原 Key。此路径会查询 Apple processing 状态。

所有上传都必须显式指定 `--execute --upload --confirmed-unused-build`、ASC 已核验未占用的 `--build-number`，以及精确的 `--upload-authorization 'UPLOAD com.fireseed.voicestudio VERSION (BUILD)'`。`--upload-mode` 默认是 `xcode-account`；指定 `api-key` 才读取 API 凭据。该参数表示操作者已经获得本次明确上传授权，不能由 agent 自行补填以推导授权。脚本不提供跳过测试的选项。Build 1 永远保留给本地验证；不得从历史 Build 6 推断 Build 7 未占用。

`xcode-account` 模式下 `uploaded=true` 只记录 Xcode 上传命令成功，processing 状态仍需在 ASC 核实；API Key 模式仅在查询返回 `VALID` 后记录 Apple 验证成功。任何上传成功但 processing 未验证、失败或查询超时的情况都应保留日志并继续核实同一构建，不能盲目重传。

签名若卡住：先执行最小副本签名验证，检查实际进程和日志；确认挂起进程已终止、保留原输出后才在新目录受控 `-jobs 1` 重试。不通过重建证书解决。

MIG-MAC-05 在 iPhone Duo / iOS 27.1 完整运行 App XCTest 与 UI Tests，并要求 66+7 项全通过；Core、Python、Node 测试也各自运行。发布入口默认仍选择首个名称以 iPhone 开头的可用模拟器；正式验收可传 `--simulator-id <UDID>` 固定设备。

Archive 不全局覆盖 CODE_SIGN_IDENTITY，以免与 Swift Package 的自动签名静态目标冲突；App target 继续使用工程内既有手动 Apple Distribution 配置和专用 profile。导出和实际签名叶证书校验固定本次验证的 identity SHA-1。
