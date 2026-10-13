# 外部方案 RinaFaceSync_v2_iCloud 核验（对照 620a366）

日期：2026-09-22。来源：`~/Downloads/RinaFaceSync_v2_iCloud.zip`（ChatGPT 生成，MANIFEST 基线 620a3662 = 当前 main）。
本文只核验，不接入；仓库代码未改。v1 核验见 `EXTERNAL_PROPOSAL_VERIFIED_ZH.md`。

## 包内测试复跑（本机 macOS，Xcode 27.0 / Swift 6.2）

| 项 | 结果 |
|---|---|
| `swift test`（FaceSyncCore，系统 sqlite3） | 42 通过 |
| `clang++ -std=c++17 Firmware/guard_test.cpp` | 13 条断言通过 |
| **AppleIntegration/*.swift 对 iOS 27 SDK 类型检查**（`-swift-version 6 -warnings-as-errors`，方案自称"未以 Apple SDK 编译"） | **通过，0 警告**。CKSyncEngine 委托签名、`RecordZoneChangeBatch`、`CKShare(recordZoneID:)` 等 API 形状均正确 |

注意：42 项里 `lostCommitReplyResumesAcrossAllNineRoutePairs` 的 `Channel` 完全忽略 `carrier` 参数，"3×3 九种载体组合"实际是 9 次相同运行；三个用 `error(_:_:)` 不带期望错误的测试只断言"抛了东西"。

## 对现有代码的断言逐条核对

| 方案断言 | 结论 | 证据 |
|---|---|---|
| 首次读取失败后 `isLocalLoaded=false`，变更入口走 `loadLocalForMutation()` | 真，一处例外 | saveLocal/rename/deleteLocal/reorder×2/importDocument 都过门；`undoLocalDelete()`（`FaceLibraryModel.swift:684`）直接 `beginLocalMutation`，靠 `localDeletion` 只能由已过门的删除产生来保证安全 |
| 撤销先进锁再读 `localDeletion` | 真 | `:685` → `:691` |
| 删除撤销记录在锁内按 ID 取 `localDocument` 当前对象 | 真 | `:715-735` |
| `commitLocal` 纯本机 | 真 | `:1059-1072` |
| `LocalFaceStore.load()` 宽松解码：坏条目 `try?` 跳过、无 diagnostics；顶层 `faces` 非数组 → 当作空 | 真 | `LocalFaceStore.swift:30-33`；`FaceDocument.swift:229-251`：`nestedUnkeyedContainer` 抛错被 `try?` 吞成 `[]` |
| 无文件分支先 `localDocument = bundledDefaults` 再 `save`；`loadLocalIfNeeded` 与 `reloadLocal` 用不同的门 | 真 | `:200-207`、`:241-248`；前者 `isLocalLoading/localLoadWaiters`，后者 `beginLocalMutation` |
| 草稿本机隔离（`DraftStorage`） | 真 | `DraftStorage.swift:3-27` |
| 128 表情含预设 / 名称 64 字节 / 文档 256 KiB | 真 | `config.h:138-140` |
| `savedFacesGeneration()` 内存计数、重启归零 | 真 | `storage.cpp:290-311` |
| 单 BLE central、最多 2 TCP、可共存 | 真 | `inbound_frame.h:11`、`transport_tcp.cpp:18`、`transport_ble.cpp:212` |
| BLOB_START/CHUNK/END/ABORT 已有，payload 4096 | 真 | `protocol.cpp:54`、`inbound_frame.h:9`；chunk 数据上限实际协商为 4032（`transport_tcp.cpp:80`），4092 只是绝对上限 |
| "最终提交前必须重新检查版本，不能只在 BLOB_START 检查一次" | **偏差：现在一次也不检查** | faces 整库导入路径 `handleBlobBegin`（`:1733-1750`）和 `handleBlobEnd`（`:2060-2091`）都没有 gen/版本校验；`gen` 409 只存在于 `GET_FACES` **下载**路径（`:2101-2116`）。方案写得比现状乐观 |
| SoftAP 同 IP `192.168.1.14`，需按 boardID 确认 | 真，且 App 已做 | `config.cpp:3`；`BoardConnection.swift:121-124,311,378-382` 已按 AP SSID 派生 boardID 比对 |
| faces 文件 tmp+rename 原子写、单文件、无独立元数据文件 | 真 | `storage.cpp:48-67,120-139`；`SAVED_FACES_PATH` 唯一 |
| 无 ESP-NOW、无板作 BLE central | 真 | 仅 `NimBLEServer` |

方案对仓库的事实陈述 0 处误读；上表"偏差"一条是把现状说得比实际好。v1 里的三条误判（commitLocal 混网络、板端 WebUI 写源、草稿共享）v2 已自行撤回。

## 新核心的独立审查（Opus reviewer，读代码 + 探针测试，未改包）

设计本身站得住：字段级寄存器 + 显式 parents、编辑基线与投递知识分离、持久化依赖 inbox、板端 epoch+revision+向量支配+事务回执。前缀连续推进、父缺失拒绝、重复按内容去重、artwork 原子、tombstone 压制离线编辑、恢复新 ID、账号命名空间、chunk 预算含 4 字节 offset、SHA-256 字节级正确（对 hashlib 15 组长度）、Swift 6 严格并发——均核实成立。

**共同缺陷：所有错误都被当作致命且全局。** 六条阻塞项：

1. `Reducer.swift:27` 重复 `entityID` 的 `create` 抛错并回滚整批，且 op 永不删除 → **两台设备各自迁移同一份 `local_faces.json`（ID 存在文件里，iPhone/iPad 相同）就永久毒化整个库**，每台拉到都进 `stop()`。迁移日第一天最可能踩到。
2. `Repository.swift:109` `local()` 以**全局** `unresolvedOperations == 0` 为门 → 任何一条依赖缺失的 inbox 条目（非原子批次部分成功后对方重装）让本机**所有**编辑永久 `.missingDependencies`，无修复 API。`CoreTests.swift:98` 把它断言为预期。
3. `CloudKitFaceSync.swift:182` catch-all → `stop()` 单向闩锁，`start()` 拒绝重启；`SQLITE_BUSY` 或离线时 `userRecordID()` 失败即永久停同步。
4. `:165-172` `.notAuthenticated/.batchRequestFailed/.limitExceeded/.partialFailure` 落 `default: throw` → 首次解锁前的后台同步就永久停。
5. `Board.swift:156`（`FacesSyncGuard.hpp:55` 同）`startupDefaultId`、预设/用户交错都不是 op、不动向量 → 只改开机默认脸时向量相同 digest 不同 → `ambiguousVersion` 永远推不上板。
6. `Board.swift:69,37-39,76-78` 库内任一脸有冲突或 startup 指向已删脸 → 所有板全部拒绝部署，无逐脸降级。

非阻塞但真实：`Transfer.swift:21` `subdata(in:)` 假设 `startIndex==0`，传 `Data` 切片会 trap；`Model.swift:160` heads 按字符串排序，`"a:10" < "a:9"` → 同一 actor 第 10 次起旧值胜出；64 writer 上限是硬砖（第 65 台自己的第一条 op 就 `.capacity`，且传到云端让所有对端 `stop()`），writerID 未要求进 keychain，每次恢复备份烧一个槽；`local()` 每次写事务两次全量 reduce（实测 400 次编辑 6.6 s，2000 次 298 s）；用户脸 ID 撞预设 ID 让 `BoardDocument.validate` 永远抛；**CKShare 接受路径完全缺失**（无 `CKAcceptSharesOperation`），跨账号共享只是草图；`failBeforeCommit` 测试钩子暴露在公开 API。

## 评价

- 方案对仓库的核对可信，且比 v1 诚实（撤回了三条误判，明确标出未做 Apple SDK 编译——这条本文已替它补上并通过）。
- 方案指出的两个本机边界（宽松解码、先赋值后写盘/双门）真实存在，是现有代码的小问题，与是否采用 v2 无关，可单独修。
- 方案漏了一条对自己有利的事实：固件 faces 整库导入**根本没有**版本检查，比"只在 START 检查一次"更糟，也更说明持久化 revision + CAS 的必要。
- **v2 核心不能原样接入。** 阻塞 1/2/5 在正常使用下必然触发且不可恢复；3/4 让 CloudKit 在常见瞬时错误下永久停摆。修法一致：隔离（quarantine）坏 op、按 actor 而非全局门控本机写、`stop()` 可恢复且区分瞬时错误、投影局部状态进 op 日志或单独计数、逐脸降级部署。
- 最大接入风险是迁移本身：必须**只在一台设备**铸造新 entityID、把预设剥出 op 日志，否则第一天就同时踩阻塞 1 和预设 ID 撞车。

## 若采纳，建议顺序

1. 先修 v2 的六条阻塞项 + heads 排序 + `subdata` 切片，补对应测试（当前每条阻塞项都无测试）。
2. 单设备迁移工具（严格解码、原始字节备份、新 ID）。
3. 固件：持久化 dataEpoch/revision/回执与 `saved_faces.json` 同一提交单元，BLOB_END 前 CAS，掉电测试。
4. 再启用真实 CloudKit；CKShare 接受路径另行实现。

## 修复记录（2026-09-22 同日）

包已落到 `ios/Packages/RinaFaceSync`（独立 SwiftPM 包，**尚未接进 App target**）。修复后经第二轮 Opus 独立审查，审查提出的 5 条阻塞项也已修完并重跑。

| 阻塞项 | 修法 | 位置 |
|---|---|---|
| 1 重复 entityID create 永久毒化 | 并发 create **合并**成同一实体（`FaceState.createIDs: [String]`，各自 name/artwork 成为额外 head；内容相同则零冲突）；语义非法 op 改为**隔离 no-op**（向量照推进、内容忽略、`LibraryState.quarantined[id]=reason`，对依赖它的 op 传递），只有 `immutableCollision`/`scopeMismatch` 仍抛错 | `Reducer.swift`、`Model.swift` |
| 2 一条 inbox 卡住全部本机写 | `local()` 去掉全局 `unresolvedOperations == 0` 门；新增 `unresolved()`、`abandonUnresolved(id)`（只接受未解析 op、**不删行**，是标记：该 op 一旦连续即按隔离 no-op 消费，避免 actor 后续历史被卡）、`unabandon(id)` | `Repository.swift` |
| 3/4 CloudKit 一次性停摆 | `SyncHalt{fatal, recoverable}`；瞬时错误不再取消引擎；ingest 失败置 `checkpointBlocked` 阻止持久化 `.stateUpdate`；`resume()` 取消旧引擎并从持久化 checkpoint 重建（`makeEngine()`），再 enqueue + fetch，成功后才清标志；`start()` 已有引擎时抛 `.busy`，可恢复停摆时委托 `resume()`；`.notAuthenticated`/`.limitExceeded` → 可恢复停摆；`.quotaExceeded` → 暂停上传保留本机；永久单条错误进 `blockedUploads`，成功后清除；ACK 时缺行跳过、内容不一致才致命 | `AppleIntegration/CloudKitFaceSync.swift`（iOS 27 SDK Swift 6 `-warnings-as-errors` 类型检查通过） |
| 5 只改开机默认脸推不上板 | `Projection.settingsVersion`（`decodeIfPresent` 兼容旧 JSON，`build` 必填）：向量相等时 settings 更大允许、相等且 digest 不同才 `ambiguousVersion`、更小为回滚；向量更新时 settings 不得倒退。C++ `preflight` 同步加 `settings` 字段，规则逐条一致 | `Board.swift`、`Firmware/FacesSyncGuard.hpp` |
| 6 一张冲突脸挡住所有板 | `Projection.build` 返回 `{projection, heldBack}`：冲突/不完整的脸若板上已有则沿用板上版本（只匹配用户脸，含后缀 id），否则暂扣；`startupDefaultId` 为 nil 保持 nil，悬空才回退到板上默认或首个预设；用户脸 id 撞预设 id 加 `-<createID>` 后缀；`DurableBoardModel.init` 进事务 | `Board.swift` |
| 小项 | heads 按 (actor, counter) 数值排序（`opIDLess`）；`BlobChunkPlan` 用 `startIndex` 偏移 | `Model.swift`、`Transfer.swift` |

App 本机库两条边界同时修了（`LocalFaceStore.swift`、`FaceLibraryModel.swift`）：`load()` 先校验顶层是对象、`faces` 存在且为数组，再用带诊断的解码；有跳过条目抛 `partiallyUnreadable(document, skippedCount)`，模型显示能解析的部分但 `isLocalLoaded=false` 禁止保存并清掉 `localDeletion`；`undoLocalDelete` 也加了 `isLocalLoaded` 门；两条加载路径改为"候选文档→写盘成功→发布"；`loadLocalIfNeeded` 与 `reloadLocal` 共用 `beginLocalMutation` 门（已核对无持锁调用）。新增 5 条本地化字符串（`sync_catalog.py --check` 0 缺失）。

验证：包 `swift test` 69 通过；C++ 19 断言；CloudKit SDK 类型检查 0 警告；App `RinaBoardTests` 全量 619 通过（第一轮修复后）、第二轮修复后 FaceLibrary* + AcceptanceLibrary + SortCache 41 通过。未接硬件、未跑真实 CloudKit。

仍未处理（审查非阻塞项）：第 65 个 writer 让 `state()` 永久抛 `.capacity`（writerID 应进 keychain，需压缩/退役策略）；`.accountChange(.signIn)` 不重建引擎；`blockedUploads` 的 op 每次启动会重试一次；每次写事务两遍全量 reduce 的 O(n) 性能；CKShare 接受路径；单设备迁移工具；固件持久化 revision/回执与 BLOB_END 前 CAS。
