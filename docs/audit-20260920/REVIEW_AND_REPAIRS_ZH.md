# 4d496201 审计复核与修复

复核基线：`4d496201f82a54457ca80ddfc558afc3048ede6e`。输入为用户提供的 `Rina_Audit_4d496201.zip` 中 31 项记录；报告作为待核实证据使用。用户授权在复核过程中修复。此工作覆盖报告所列问题及其直接关联路径，不宣称完成全仓库逐行审计。

保留了工作区原有的 `InfoPlist.xcstrings` 修改与 `.claude/merge-backup/`。未提交 Git commit、推送或刷写设备。

## 逐项处置

| 编号 | 复核结论与实际处置 |
| --- | --- |
| R01 | 确认并修复。普通命令、表情修改、Wi-Fi 查询、Blob 上传在入队前保存连接代次/载体身份；执行及发布结果时验证。BLE 写入冻结连接尝试、外设和特征对象。保留部分帧 finish-or-close 与原连接 Blob 清理。 |
| R02 | 确认并修复。整库导入成功和失败均验证页面绑定修订，旧板不能覆盖新板列表或错误。 |
| R03 | 确认并修复。手动 step 返回后检查运行身份、计时版本、主板、代次和租约，不能复活已停止轮播。 |
| R04 | 确认并修复。以最后成功显示的稳定 face ID 定位；自动 tick 和手动前后切换使用明确候选索引。 |
| R05 | 确认并修复。输出所有权运行 ID 与计时修订分开，重设计时不再重新 claim 输出。 |
| R06 | 确认并修复。组准备从入口持有 preparationID；Stop、新 Play、接管与控制抢占使旧准备失效。 |
| R07 | API 边界加固。仅在同组、同播放 epoch 内合并可选 fps/loop 更新；原文字 UI 已提交完整参数，未声称复现 UI 丢值。 |
| R08 | 确认旧任务清理风险并修复。接管任务持有 attemptID，仅当前任务能清理句柄和失败状态。 |
| R09 | 确认并修复时间配对。选取首个成员帧序号时保留该成员读数完成时间，不再使用整轮读取结束时间。尚未实现完整 RTT/不确定度估计。 |
| R10 | 确认并修复。参数对齐等待必要字段 ACK，错误按字段保留，重试有次数上限与延迟；每字段提交 UUID 防止旧 ACK 或重试覆盖新值，队列限额保留必要对齐条目，其他字段成功不能抹掉失败。 |
| R11 | 协议输入加固。正常 ACK 必须携带且等于本块末尾；raw scroll 起点/恢复偏移遵守 47 字节边界。未声称正常固件曾跳过数据。 |
| R12 | 协议输入加固。GET_FACES 短包显式失败；整个分页过程绑定原连接，完整成功后才发布 generation。 |
| R13 | API 边界加固。requestReliable 的 CommandReply 检查 ok；通用 typed decoding 仍由调用者解释业务字段。 |
| R14 | 确认并修复。获得本地事务门后读取撤销记录；删除使用当前权威文档中的对象。 |
| R15 | 确认并修复。读取失败时默认表情仅用于显示，不标记已成功加载；本地修改路径拒绝写回，保留损坏原文件。 |
| R16 | 确认并修复。名称预留普通、翻译和编号副本后缀预算，按完整字素截断至 64 UTF-8 字节；保存边界再次限制。 |
| R17 | 保留为性能假设。没有 Profile/signpost 热点证据，不做检索索引或架构重写。 |
| R18 | 确认并修复。组 Stop 与 all-online 解耦，准备中也可停止；先撤销本地意图，再向在线成员发送停止，保留离线与拒绝结果。 |
| R19 | 修正证据不符的 UI 标签为“面板配置帧率”“播放指令确认”，补齐四语言资源。未实现或宣称物理呈现相位/实测 FPS。 |
| R20 | 确认并修复。文字恢复重试持有绑定修订与任务句柄；换板/释放输出使其失效。 |
| R21 | 确认并修复。上传进度/完成/清理按 uploadRevision 保护；调速按独立 pending ID、绑定修订、时间线与连接代次确认。 |
| R22 | 确认并修复。Stop 同步清理 isStarting/startingGroupID，旧启动收尾不能覆盖新启动。 |
| R23 | 确认并修复。组队列条目冻结提交租约、dispatch revision、连接代次，不能借用后来的租约。 |
| R24 | 确认身份判断缺口并修复。自动连接只将匹配物理 ID 的连接计为成功；已连接的错误别名不反复重拨。BoardStore 不再仅凭共享/复用 IP 合并旧记录。 |
| R25 | 确认并修复。Bonjour browser 批次和 resolver 各自持有身份，停止先失效，旧回调不能发布或清理新 resolver。尚未做真实网络回调压力验证。 |
| R26 | 保留为性能假设。没有 Instruments 数据，未改变预览观察结构。 |
| R27 | 条件风险加固。目标、连接代次和视图消失时结束 fpsEditing 并撤销旧提交；物理拖动中移除 Slider 尚未真机验证。 |
| R28 | 修正文档。区分 iOS 17 部署目标、较新 SDK 引用、实际验证的 Xcode 27.0；保持 Swift 5 App / Swift 6 RinaCore。严格并发结果见下文。 |
| R29 | 确认并修复。分配前验证无符号 totalBytes、47 字节对齐、帧数上限和追加后数量。保留零帧及 totalFrames 表示最终分批目标的旧协议语义。 |
| R30 | 确认并修复。先 measureJson 并检查 document overflow，完整编码后分帧，容量不足返回 ERR；缓冲考虑最坏六倍 JSON 转义。同步修正状态 JSON 的结构容量，避免完整性检查拒绝正常状态。 |
| R31 | 确认并修复已列读写点。注册表标志读取使用同一锁；回调访问入站缓冲按 registry→inbound 顺序持锁；日志计数在日志锁内读取。未完成 ESP32 真机并发压力验证。 |

## 回归与验证

新增/扩充的回归使用实际 App 类和可控传输，覆盖排队命令/表情删除/上传跨重连、短分页、异常 ACK、轮播中止与索引、部分离线停止、准备取消、旧板导入/文字恢复、本地损坏文件保留、撤销交错、UTF-8 副本名称、物理身份不符等。

固件 `test/host/audit_protocol_test.py` 编译生产 `protocol.cpp`，使用 ASan/UBSan 验证分配边界、分批追加、最坏转义 JSON 完整性和超限 ERR。已有 `stress_findings_test.py` 补齐了当前协议新增符号所需的宿主桩。

- Xcode：27.0，build 27A266a；模拟器：iPhone 17 Pro / iOS 26.5。
- RinaCore：371 项，11 项跳过，0 失败。
- App 完整测试：590 项，0 失败。最后组参数修订后另跑 51 项受影响套件（含 3 项新增回归），0 失败。
- ESP32-S3 RMT DMA：PlatformIO 最终构建成功。
- 固件宿主测试：最终修订重跑，事件 14 项、上传/边界 67 项通过；新增审计边界 ASan/UBSan 测试通过。
- 严格并发：修复版和原提交在同一 Xcode 下均为 50 个告警位置，按文件与诊断文本对比无新增；最后增量修改的严格并发构建亦成功且无新增诊断。仓库脚本阈值仍为 44，因此该检查**未通过**；未提高阈值或宣称完成 Swift 6 迁移。
- 本地化：源码 652 个 key 无缺失；新增文案四语言齐全，翻译应用检查 0 待修改。同步检查仍被原提交就存在的 16 个 stale 标记阻止，未修改这些无关条目。
- 真机 BLE、ESP32 多板时序/锁压力、Instruments、最低 SDK 和 Release/Profile 对照尚未验证。

## 本轮验证命令

```sh
swift test --package-path ios/Packages/RinaCore --scratch-path /tmp/rina-audit-core
xcodebuild test -project ios/RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,id=53787319-2C1D-474F-9C2C-CD398583E554' \
  -derivedDataPath /tmp/rina-audit-dd -only-testing:RinaBoardTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 CODE_SIGNING_ALLOWED=NO
python3 esp32s3_firmware/test/host/audit_protocol_test.py
python3 esp32s3_firmware/test/host/stress_findings_test.py
/Users/sager/.platformio/penv/bin/pio run -d esp32s3_firmware -e esp32s3-rmt-dma
RINA_VERIFY_DIR=/tmp/rina-audit-strict bash tools/verify_ios.sh concurrency
```

临时完整日志在 `/tmp/rina-audit-*.log`，App xcresult 在 `/tmp/rina-audit-dd/Logs/Test/`；原提交严格并发对照在 `/tmp/rina-audit-baseline-strict/`。上述目录是本机临时验证产物，不作为仓库长期依赖。
