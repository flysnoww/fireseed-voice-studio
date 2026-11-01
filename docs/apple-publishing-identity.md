# Voice Studio Apple 发布身份卡

更新：2026-10-31。项目事实来源：`docs/mac-local-release.md`、`docs/testflight-release.md` 和本地 ASC 记录；中央 Team/API 凭据索引见 [Fireseed Apple 发布身份与凭据索引](../../.workflow/apple-publishing-identity.md)。全局身份只在中央索引维护。

## App 标识与 TestFlight

| 字段 | 已核实值 |
|---|---|
| App 名称 | Voice Studio |
| ASC App ID | `6816751639` |
| iOS Bundle ID | `com.fireseed.voicestudio` |
| Watch App / Extension Bundle ID | 当前发行目标无已核实的独立 Watch Bundle ID；如 target 变化，先检查工程与 ASC。 |
| Apple Team ID | 见中央索引 |
| 内部测试组 | `内部测试`；UUID `2d5ce665-0179-4dc8-92c2-89839e11ae5a` |
| 最近成功上传 | `0.1 (13)`，2026-10-23；Delivery UUID `80384bb2-4a26-4666-b3f3-be32a42178d8` |
| ASC 状态 | 上传完成并可供内部测试；不要据此声称所有后续版本已安装验收。 |

## 签名配置

| Target | Profile | UUID | 状态 |
|---|---|---|---|
| iOS | `Voice Studio App Store Distribution` | `a8e11b5d-555a-4ca1-a638-697d114e8f97` | 2026-10-31 本机记录；新 Archive 需检查 Profile 是否仍有效且含目标证书。 |

当前证书身份见中央索引。Voice Studio 曾进行证书/Profile 轮换；不要使用旧发布记录替代本机实际 Profile 检查。

## 认证、查询与上传

- ASC Build/Upload 查询：`scripts/asc-build-query.py`，环境变量 `API_KEY_ID`、`API_ISSUER_ID`；默认私钥路径见中央索引。也有使用已认证 ASC 网页会话做全状态/全分页查询的历史证据。
- 最近 Build 13 使用当时有效的 Xcode 账号上传，ASC 回执及内部组状态见 `local-releases/upload-existing-6816751639-0.1-13-20261023/`。
- 本轮没有执行 Voice Studio 实时 ASC API 查询；查询凭据的当前运行态见中央索引，不要因历史查询成功就假设本轮认证有效。

## 版本与复核入口

- 版本/Build floor 与脚本入口：`docs/mac-local-release.md`、`docs/testflight-release.md`、`scripts/local-ios-release.py`。
- 历史发布证据位于本机 `local-releases/` 忽略目录；不要将含原始日志或私有产物的数据复制到 Git。
