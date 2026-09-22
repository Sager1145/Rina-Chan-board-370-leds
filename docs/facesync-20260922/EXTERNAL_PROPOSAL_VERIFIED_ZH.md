# 外部方案 RinaFaceSync_v1 核验（对照 4d49620）

日期：2026-09-22。来源：`~/Downloads/RinaFaceSync_v1.zip`（ChatGPT 生成，MANIFEST 基线 4d496201 = 当前 origin/main）。
本文只核验，不接入；仓库代码未改。

## 包内测试复跑（本机 macOS）

| 项 | 结果 |
|---|---|
| `python3 -m unittest discover -s tests`（Python 3.9.6，README 要求 3.11+） | 40 通过，2.0 s |
| `python3 demo.py` | 5 步全部通过 |
| `swift test`（Xcode 工具链，arm64 macOS，swift-tools 6.0，platforms iOS 17） | 5 通过 |

测试完全自包含，不碰仓库、不碰设备。

## 对现有代码的断言逐条核对

| 方案断言 | 结论 | 证据 |
|---|---|---|
| `applySavedFace(index:)` 按面板排序列表的索引发送 | 真 | `BoardConnection+Faces.swift:10`，`FaceLibraryModel.swift:369` 用 `cachedBoardSortedFaces.firstIndex` |
| `commitLocal()` 里塞了网络同步，建议让它退出 | **假** | `FaceLibraryModel.swift:1059` 只写 `localStore` 并更新内存；写板走独立的 `connection.faceUpsert`（:427） |
| `LocalFaceStore` → `local_faces.json`，`.atomic` 写 | 真 | `LocalFaceStore.swift:26,38` |
| `ControlViewModel.editingFaceId` 没记录编辑基线 | 真 | `ControlViewModel.swift:86`；只有 `editingFaceCanOverwrite`，无快照 |
| 每部手机各自产生 `F000001` 编号会冲突 | 真 | `FaceNumberRegistry.swift`：UserDefaults 内、按 local/板物理 id 分 scope、不回收；注释明说"不是跨设备协议字段" |
| 草稿是共享的 `face.json`，多手机会互相覆盖 | 偏差 | `DraftStorage` 写在本机 Application Support/Drafts/face.json，本来就按设备隔离；只是跨板共用一份（切板丢草稿已是决定，见 memory） |
| 预设由各手机按自己 bundle 改写共享库 | 偏差 | `bundledDefaults` 只合并进**本机**库（:231-257）；面板默认表情来自固件，App 不推送预设 |
| `connectionGeneration` 只识别旧连接回包 | 真 | `BoardConnection.swift:40,245` |
| 固件有 `writeSavedFaces / writeJsonFileAtomic / savedFacesGeneration` | 真，但 | generation 是 `static uint32_t` 内存计数（`storage.cpp:290`），**重启归 0**；tmp+rename 以 LittleFS rename 为提交点 |
| `faceUpsert` 是绕过版本控制的写入口 | 半假 | 所有变更走 `mutateFacesDocument`（`protocol.cpp:669`）读→改→校验→原子写→gen++；App 侧还有 `lastFaceOpGenMatchedExpectation`。缺的是**持久化**版本，不是没有版本 |
| 面板 WebUI／本地按键能独立增删改表情，需要板端操作日志 | **假** | `web_setup.cpp:378-386` 只有 Wi-Fi 路由；无其它 HTTP 服务、无按键写库。板端唯一写源就是手机协议 |
| 需要新增 BEGIN/CHUNK/COMMIT 分块提交 | 已有雏形 | `BLOB_START/…/BLOB_END/ABORT` 整库导入；`GET_FACES{offset,gen}` gen 不符返回 409。缺的是耐久 transactionID |
| 固件没有 HTTPS 客户端 | 真（方案自己也承认） | 只有 `transport_tcp.cpp` 的本地 TCP **服务端** |
| 面板缺持久化 boardID/dataEpoch/storageRevision | 真 | `boardId()` 由 BT MAC 派生；`boardBootId()` 每次开机随机 |
| "读取失败不代表空资料库" 是新要求 | 已实现 | `FaceLibraryModel.swift:209-220`：load 失败显示默认库但 `isLocalLoaded=false` 阻断写盘 |
| 仓库里没有任何多手机／云同步设计 | 真 | docs/.claude/git log 均无；这是全新领域 |

方案未提到的真实约束：`MAX_AUTO_FACES = 128`、`MAX_FACES_DOCUMENT_BYTES = 256 KiB`（`config.h:138,140`）；BoardMirror 默认 256 只是测试值。
板端新表情 id 为 `custom_<millis base36>`，手机本机为 `local_<uuid>`；不同板的 `custom_*` 理论上可撞，方案第 11.3 节"旧 ID 相同不等于同一对象"这条对本仓库成立。

## 评价

**设计本身站得住**：字段级多值寄存器＋编辑基线 parents、上传回执不推进下载游标、每板独立 CAS＋幂等 transactionID、删除 tombstone＋恢复新 ID，这些规则与参考实现一致，40 项测试覆盖到位（含 100 组乱序投递）。`artwork` 作为不可拆分字段组与 `SavedFace`（type/frameHex/call）完全对得上。

**误判／多余的部分**：
1. 把 `commitLocal` 说成混有网络同步，并以此推导"要让它退出持久化核心"，前提不成立；现有本机保存已经是纯本机、原子、失败不覆盖。
2. "面板双向操作日志、签名转发、手机冒充校验"整章针对一个不存在的写源（板上没有 WebUI 编辑）。除非以后加板端编辑，这部分可整体砍掉。
3. "草稿隔离"和"读取失败进恢复态"是已有行为，不是待办。

**真正的缺口（接入前必须解决）**：
1. 固件需要**持久化**的 storageRevision/dataEpoch/transaction 回执，并与 `saved_faces.json` 同一提交单元；现在的 generation 一重启就归零，CAS 无从谈起。
2. 手机需要一个事务仓储（SQLite）取代整库 JSON 写，方案的 Swift 包只给了 wire 模型和 `FaceReplicaRepository` 协议，仓储、reducer、SwiftUI 接入全部未写。
3. 需要一个**常驻服务器**（SyncHub）加账号、邀请、撤权、TLS 运维。方案一句话否掉了"多手机同一 Apple ID"，没有评估 CloudKit（私有库＋CKShare 邀请其他 Apple ID、内置推送与鉴权）。对这个项目的规模，CloudKit 承载同一套操作日志更省运维；服务端 serial 分配可改为 CloudKit 记录上的乐观锁计数或干脆保留本机编号为显示别名。这是接入前最该先定的决定。
4. 编辑基线：`ControlViewModel` 要在打开编辑器时冻结 `baseHeads`，这条方案说得对，现在没有。

## 建议的落地顺序（若采纳）

1. 先决定同步后端（自建 HTTPS vs CloudKit）。
2. iOS：SQLite 事务仓储＋outbox，保留现有 UI；`LocalFaceStore` 降为迁移读取器。
3. 固件：持久化 revision＋幂等 COMMIT 回执，复用现有 BLOB 分块通道，做断电测试。
4. 多板逐板回执 UI。
砍掉：板端操作日志、签名转发、面板 Wi-Fi 直连（固件无 HTTP 客户端，且 BLE/TCP 经手机已够）。
