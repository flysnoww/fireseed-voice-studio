# Voice Studio — Fireseed Identity V1

## 配置与边界

本次接入授权为声音应用增加身份归属，不增加云同步、跨应用业务数据共享、账户绑定或账户删除。Identity 服务仅处理身份。私人声音仍保存在当前设备的 Voice Studio 沙盒中。

| 参数 | Voice Studio 专用值 |
| --- | --- |
| Native Application | Voice Studio PRODUCTION |
| Public Client ID | `ghducpbvjml6ovk92e392` |
| Endpoint | `https://auth.fireseed.work` |
| Issuer | `https://auth.fireseed.work/oidc` |
| Discovery | `https://auth.fireseed.work/oidc/.well-known/openid-configuration` |
| 登录回调 | `com.fireseed.voicestudio://oauth/callback` |
| 登出回调 | `com.fireseed.voicestudio://oauth/signed-out` |
| Scheme | `com.fireseed.voicestudio` |
| Apple social connector | `fo8oqzueaxapk6iw625lf` |
| Google social connector | `e8kbgsw287oxnop4gr4dt` |

2026-10-20 通过已有私网 SSH 和已登录的 Logto Console 核实服务为 1.44.0，原先仅登记 AIQuickNote。取得针对新 Native Client 的确认后创建上述应用，分别保存两个回调，并在新应用详情核验；没有修改 AIQuickNote 登记、连接器凭据、认证策略或服务部署。只读复核 `automaticAccountLinking=false`；不按相同邮箱合并用户。上述 Client ID 和 connector ID 是公开标识，不是 Client Secret。PRODUCTION 是此应用明确的构建配置；没有把 AIQuickNote 的 STAGING Client ID 放进 Voice Studio。

## 复用与依赖

只读审计本机 `../AIQuickNote/ios/AIQuickNote/LogtoIdentityProvider.swift`、`FireseedIdentityKit.swift` 与该项目 Identity/发布文档。沿用已验证的 Logto SDK 适配模式和系统认证会话，不复制 QuickNote 的业务数据模型、客户登记或发布参数。

锁定 Logto Swift SDK `2.0.0-beta.1`（`fdc4a979d1d940dc58c9c3c8553ede4eb696186c`），JOSESwift `3.0.0`，KeychainAccess `4.2.2`。这是参考项目实际验收版本；官方文档现在也列有 2.0.0，未未经独立验证就替换参考版本。前两项分别为 MIT / Apache-2.0，KeychainAccess 为 MIT；完整许可证随 App 的 `IdentityThirdPartyNotices.txt` 打包。iOS 17.0 主工程兼容 SDK 的 iOS 13 最低要求。

`VoiceStudioIdentity.swift` 的 `StudioLogtoProvider` 是唯一 SDK 边界。Apple/Google 按钮进入 `ASWebAuthenticationSession`，使用共享 Logto 的已有 social connector；这不是独立接入 Apple/Google 私钥的原生 SDK。SDK 负责 OIDC discovery、随机 state、PKCE S256、code exchange、JWKS/签名、issuer/audience/expiry 校验。当前是授权码流程，未额外声明使用 nonce；不把不存在的 nonce 校验写成已验证。

`StudioIdentitySession` 串行执行认证操作。重复点击不会创建并发登录；退出立即隐藏身份与数据，并等待已失效操作结束/清除凭据后才允许下一次登录。过期 access token 由 SDK 刷新；冷启动通过 refresh + authenticated UserInfo 恢复身份。恢复失败或前台复核发现身份不一致时清除会话并重新认证。网络请求超时为 30 秒，资源超时为 90 秒；系统登录浏览器可由用户取消。SDK 的浏览器会话不提供外部取消接口，因此有未结束的认证会话时不启动第二个，不能仅用 UI 状态假装它已结束。

Token 仅进入 SDK 管理的 app 默认 Keychain access group（服务 `io.logto.client`），不配置跨 App Keychain sharing。每次成功登录/恢复后检查 SDK 确实存入 ID/refresh token，并将这两个 app-owned 项的可访问性约束为 `WhenUnlockedThisDeviceOnly`；Keychain 写入失败不返回登录成功。显示名只在内存，身份索引仅保存 issuer/sub，不以 email 合并。日志不输出 token、授权码、完整授权 URL 或管理员凭据。无签名 Simulator 的 Keychain 错误不能作为真实存储 PASS。

## 数据资产清单

| 既有数据 | 归属与处理 |
| --- | --- |
| `ManagedAudio/` | 私人原始录音、导入参考音、生成音频；不可重建，必须保留 |
| `Metadata/audio-*.json`、`voice-*.json` | 私人声音/音频记录；引用稳定 UUID 文件名及关联资产；历史版本没有 owner |
| `voice-selection.json` | Current Voice 与系统声音的用户调整；按账号恢复 |
| `StagedAudio/` | 未保存录音/导入/生成缓存；临时内容，不自动认领为长期资产；历史目录不清理 |
| `Appearance/`、背景照片偏好 | 私人选图；随认领复制，之后按账号目录和 defaults suite 隔离 |
| `RendererPacks/`、Kitten/Qwen 模型包 | 公共模型，可以共享；不包含在私人音频迁移副本中 |
| `RendererCache/`、speaker embeddings | 可重建但可能源自私人音频；新版本按账号存放，旧全局缓存不复用 |
| 预览/生成缓存与当前模仿参考 | 账号上下文持有，退出取消任务、停止播放并撤销旧文件访问 |
| 语言设置 | 设备偏好，可以共享，不是私人声音资产 |
| 诊断 breadcrumbs | 账号独立 UserDefaults suite；账号 UI 不显示全设备旧 MetricKit 报告 |
| Share Sheet / 导出副本 | 创建时经过当前 store 的文件访问检查；切换账号撤销 App 中的 lease/界面。已经由用户分享到其他 App 的副本无法被本 App 追溯撤回 |

没有发现 EventKit、系统提醒、业务云数据库或现有 Keychain/OIDC 登录实现。Share Sheet 是音频导出边界；系统/本地模型生成、录音、导入、声音调整及模仿仍由现有模型和服务负责。

## 持久化与账号隔离

`IdentityWorkspace` 使用经过验证的精确 `(issuer, sub)`，对确定性编码做 SHA-256 获得目录名。每个账号目录保存 `owner.json`，并通过 `current.json` 指向自己的 `Versions/<UUID>/`。所有私人 Metadata、ManagedAudio、Current Voice 和私人缓存位于该版本目录。源域模型结构仍保持 model-neutral；归属由不可混用的工作区 manifest 和文件根目录确定，不用邮箱或声音名称推断所有权。

账号变化会建立新的 `VoiceStudioModel`，旧 store 立即失效：读取、播放/分享取 URL、持久写入和删除全部拒绝。异步任务捕获的是旧 model/store，不能写入新账号目录。录音权限回调与渲染任务另有现有 generation/cancellation 检查。新账号不会继承旧模型中的 Current Voice、音频列表、搜索/卡片层级或模仿参考。文件访问拒绝 symlink，不能伪造文件名把另一个账号的文件传给当前 store。

游客使用单次临时目录；可以尝试系统声音、生成和临时录音/导入。第一次 Save 调用身份请求，不落无归属的持久记录。取消登录保留当前临时内容。游客成功登录时仅复制尚未保存的 draft 到该账号的临时区域，登录本身不保存；用户必须再次明确点击 Save。退出后声音文件不会删除。

## 历史资产主动认领与故障恢复

升级不移动、删除、重命名或自动分配原来的 `VoiceStudio/ManagedAudio`、`Metadata`。登录后账号页提示本机历史记录数量，只有用户确认“Back up and claim sounds”才认领。没有确认不合并到任何账号。

认领步骤：

1. 停止当前模型的任务并撤销旧文件访问。
2. 验证所有历史 JSON 可以解码、UUID 文件名与关联音频存在，拒绝 symlink 和不完整库。
3. 在新版本目录准备当前账号数据的副本；旧 active version 继续保留。
4. 将历史私人文件复制到 `LegacyBackups/<revision>/`，逐文件 SHA-256 校验；原历史目录也不修改。
5. 合并到准备目录，冲突文件必须字节相同；不覆盖账号已有的 Current Voice。
6. 原子写入包含 owner、revision 和哈希清单的 `legacy-claim.json`，再原子切换此账号的 `current.json`，最后写完成记录。

任何提交前失败都不会把半迁移目录显示为库；原文件、备份和旧版本保留。若进程恰在 journal 与 pointer 之间终止，下次只有同一个 owner 可以恢复已提交认领，其他账号不能继承。重复认领不会复制第二套资产，也不把当前指针倒退到旧版本。旧 Asset ID、相对音频名、声音配置和关联保持。迁移备份的清理/数据彻底擦除是另一个显式授权事项；App 普通删除只作用于当前库，不声称清除了迁移备份。

不要人工修改 owner/journal 或把目录移动给另一个账号。需要回滚时，先停止 App、复制完整 VoiceStudio 数据目录和 manifests 到私有备份，再在确认目标 owner 后恢复该账号之前的 `current.json` 及对应版本；原始历史文件仍可恢复。不要通过删除文件解决认领失败。

## 自动化、真实服务和发布

Core、App 和 UI 层分开测试。`-ui-regression` 仍是原功能的合成 fixture；`-ui-identity` 用两个显式注入的测试身份和独立临时库验证 UI，不连接 Apple/Google。XCTest host 也不使用真实 Keychain session。Release 不包含这些 DEBUG 入口，配置失败不选择 mock。

```sh
swift test --package-path ios/VoiceStudioCore -Xswiftc -strict-concurrency=complete
python3 -m unittest discover -s scripts -p 'test*.py'
npm test
python3 scripts/local-ios-release.py --dry-run
python3 scripts/identity-service-preflight.py --report /tmp/voicestudio-identity-service.json
# 全部测试、构建、签名、Archive 和 IPA；不上传。
# 8 是 2026-10-20 全部上传状态核查后选出的本次候选，不是可长期复用的默认编号。
python3 scripts/local-ios-release.py --execute --version 0.1 --build-number 8 \
  --simulator-id 9458EE19-AF52-4318-8FFE-6E677CDF32DA \
  --output local-releases/Identity-V1-preflight-0.1-8
```

默认 dry-run 不指定任何构建号；执行必须显式给出，所有 Xcode 阶段使用同一版本/构建号。上传额外要求干净且已提交的 Git 工作树、本次具体 Build 的明确授权及 ASC 全状态未占用确认。上传前使用 IPA 实际配置再次执行无登录的真实 OIDC preflight。不要重传本次验证目录或 Build 7，不进入正式 App Store 审核。

Archive 与 IPA 会检查专用 Client ID、环境、Issuer、两个 callback、URL scheme、布尔出口合规值、签名、Bundle/Team/profile 和版本；测试要求原有测试加 Identity/UI 测试全部运行、零失败、零跳过。新增 Logto/JOSESwift/KeychainAccess 已重新审计：实际认证使用 TLS、PKCE SHA-256、系统 Security 签名校验和 Keychain；JOSESwift 中的 AES/RSA/EC/HMAC/PBKDF 包装调用 Apple CryptoKit/CommonCrypto/Security，没有引入外部密码算法库或专有加密。声明继续为 `ITSAppUsesNonExemptEncryption = false`，最终产物仍必须通过 preflight。

正式 Apple/Google 登录、真实 refresh/过期/离线/撤销行为和实体 iPhone 的历史资产认领需独立验收。自动化 fixture 结果不能替代这些结论。执行证据和最终状态保存在忽略的 `local-releases/identity-v1-evidence/` 与本次 preflight 输出；私人音频、token、Keychain、IPA 和 Archive 不提交 Git。

官方依据：[Logto Swift](https://docs.logto.io/quick-starts/swift)、[Apple 出口合规](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)。


## 2026-10-20 本次验收记录

| 项目 | 实际结果 | 证据 |
| --- | --- | --- |
| Core | PASS 42/42（原有 30 + Identity/迁移 12） | `local-releases/identity-v1-evidence/core-final.log` |
| App XCTest | PASS 77/77（原有 66 + Identity 11） | `local-releases/identity-v1-evidence/AppFinal.xcresult` |
| UI | PASS 9/9（原有 7 + Identity 2） | `local-releases/Identity-V1-preflight-0.1-8/Tests.xcresult` |
| Python | PASS 24/24 | `local-releases/identity-v1-evidence/python-final.log` |
| Node | PASS 7/7 | `local-releases/Identity-V1-preflight-0.1-8/node-tests.log` |
| 最终分层合计 | PASS 159；FAIL 0；skipped 0 | 以上分别实际运行，不把重复运行累计为新增测试 |
| Debug / Release | PASS；实际配置 0.1 (8)、专用 Identity 参数、布尔 false | preflight 构建日志及 config JSON；最终 Debug 再查 `debug-final-config.json` |
| Distribution / profile | PASS；现有 Tao Wu / Z36ZADH7T7；profile UUID `fa3f93de-933a-493c-be0a-3e85c0a66c69`，至 2027-09-27 | `archive-preflight.json`、`ipa-preflight.json` |
| Archive / IPA | PASS；Bundle 正确，0.1 (8)，MinimumOSVersion 17.0，ONNX framework 已验证 | `local-releases/Identity-V1-preflight-0.1-8/` |
| 真实 OIDC 无登录路径 | PASS；discovery、JWKS、S256、专用 client/callback、state 与 `login_required` | `identity-v1-evidence/ipa-identity-service-preflight.json` |
| 真实 Apple / Google 用户登录 | NOT TESTED | 未用自动化 fixture 冒充用户登录 |
| 真实 Token 刷新/离线/冷启动 | NOT TESTED；对应模型化状态机测试 PASS | 无签名 Simulator 的结果不证明真实 Keychain 写入；实际适配器会校验 Keychain 写入并在失败时拒绝登录 |
| 模拟器既有生产库 | PASS 只读清单：0 个 voice、0 个 audio record、0 个 managed/staged 文件；非手机数量 | `identity-v1-evidence/simulator-assets-before.json` |
| 实体 iPhone 既有资产、备份及认领 | NOT TESTED；设备未连接，未修改手机数据 | 不能把模拟器的 0 当成用户手机的 0；需在新版本安装后的明确认领中检查原始数据和备份 |
| ASC 构建号 | PASS 只读核对全部上传状态、展开所有记录：0.1 的 1–7 已用，1 为失败，最高 7，未见 8 | `identity-v1-evidence/asc-build-audit.json` |
| 本次上传 / Apple 处理 / 真机安装 | BLOCKED / NOT TESTED / NOT TESTED | `result.json` 为 `PASS_LOCAL_NO_UPLOAD`、`uploaded=false`；缺少本次 Build 8 的明确上传授权 |

发布入口的一次完整 App/UI 运行通过 76 + 9 = 85 项；随后补充启动失败保护并对最终 App 源码完整重跑 77 项。Core 和 Python 的最终扩充套件另行完整重跑。未来发布入口门禁提高为 App 77 + UI 9 = 至少 86 项，零失败、零跳过。

修复过程中的实际失败也保留：首次保存 Sheet 未继承 account 环境对象导致崩溃，已明确注入并通过定点及完整 UI；新测试最初误将现有的“保存后禁用”控件判断为“保存后消失”，已按实际既有语义改为断言“登录后仍可保存、明确保存后禁用且显示持久化成功”；原有 7 项 UI 与断言未删除、未跳过、未降低。迁移测试还定位了 `/var` 与 `/private/var` 枚举差异，修复为一致规范化路径。失败日志在本次 evidence 目录，最终结果采用后续真实通过的运行。

此阶段为 **本地开发、迁移测试和发布准备 PASS**，整体 Identity V1 **尚未 COMPLETE**。下一步须获得 0.1 (8) 单次上传授权，上传前刷新 ASC 未占用核验，再依已有 Xcode 账号流程上传一次；之后由真实 iPhone 验收 Apple/Google、退出重登、冷启动、过期/刷新、跨账号资产与旧库认领。禁止正式 App Store 审核。


## 2026-10-20 获授权的 Build 8 单次上传

发布源码 SHA：`84a8abfa8ed6bcfeb07ee9377b32dc788c13ee05`，上传前工作区干净，45 个 ios/scripts 文件的 SHA-256 与已验收产物清单一致，IPA SHA-256 为 `93ec3d64c3810b5baec14a9dd1cdb95413e1bcad129318ac1f72f18f78238c85`。本次复用此前实际通过的 159 项测试和已签名 Archive，没有将历史测试写成本次重跑。Archive、IPA 签名及线上无登录 OIDC 预检在上传前重新执行并通过。

用户明确授权仅上传 VoiceStudio 0.1 (8)。ASC 上传前只读检查“所有状态”、展开全部历史，1–7 已使用，8 不存在。使用现有 Xcode 登录账号，对 `local-releases/Identity-V1-preflight-0.1-8/committed/VoiceStudio.xcarchive` 执行一次 `xcodebuild -exportArchive`，导出配置保持项目既有 profile/Team/证书，改为 `destination=upload`，`method=app-store-connect`，`manageAppVersionAndBuildNumber=false`。无 P8、无证书变更、无正式审核。

上传 UTC 时间为 2026-10-20 07:57:43 至 07:58:40，退出码 0，明确回执 `Upload succeeded.` / `Uploaded package is processing.` / `EXPORT SUCCEEDED`。ASC 已出现 0.1 (8)，记录 ID `6bb6d129-b682-4665-9f1f-ace57330e069`，初次查询为“正在处理”。现有“内部测试”群组有 3 位测试员，设置为“自动分发 Xcode 构建版本”；处理期间尚不能将此配置称为 Build 8 已可安装。

非阻断警告：供应商 `onnxruntime.framework` 缺少 UUID `835932C6-0955-3329-809C-DF68FA3D9E88` 对应 dSYM，影响该 framework 的崩溃符号化；Apple 上传成功，不因此重传。

完整命令、一次性尝试账本、上传日志、分发日志与只读 ASC 证据保存在被忽略的 `local-releases/Identity-V1-upload-0.1-8/`，禁止提交其中产物或凭据。上传结果不明时先查该账本与 ASC，不能自动重试。实体 iPhone Apple/Google 登录、真实 token 生命周期、账号隔离及历史声音备份认领仍需用户验收；保持已有声音数据，不卸载或重置 App。

最终只读复核：Apple 已处理完成，0.1 (8) 自动加入现有“内部测试”群组，群组构建列表明确显示“正在测试”、90 天后过期。因此 **UPLOAD SUCCESS / READY TO TEST / 内部测试员可安装 PASS**；实体 iPhone 实际安装与登录验收仍为 **NOT TESTED**。最终证据为 `asc-ready.txt`、`asc-ready.png` 和 `upload-result.json`。本次仅一次上传，未开始 Build 9，未提交正式审核。
