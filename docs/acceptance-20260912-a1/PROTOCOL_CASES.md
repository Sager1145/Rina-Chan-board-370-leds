# 通信、持久化、恢复与 Debug 验收

日期：2026-09-12。范围：当前工作区静态审查与待执行用例设计。**本文件所有用例均未测试；没有运行测试、模拟器或硬件。** 历史修复文档中的 136 Core / 10 App / 2 UI 通过记录不等于本次复验通过。读取了 ios-dev、guide-swift-testing 与 gpt-model-router；仓库及其父目录搜索未找到额外 AGENTS.md。本次未改产品代码；后续授权新增4项Debug回归测试，尚未执行。

## 现有自动化实际覆盖（源码核查，未运行）

| 文件/位置 | 已有断言范围 | 不能据此证明的行为 |
|---|---|---|
| `ios/RinaBoardTests/BoardConnectionOutputTests.swift:8`、`:68`、`:107` | 旧会话排队帧不发送、取消在途 continuation、新帧继续与旧应答隔离、旧连接晚完成不覆盖新连接 | 真实 BLE/TCP、超过 2 秒迟到+序号绕回、连接 ViewModel 配网流程隔离 |
| 同文件 `:48` | 普通 CMD `ok:false` 抛错 | 所有协议错误码、Debug 拒绝统计、blob 回滚 |
| `ios/RinaBoardTests/BoardPlaybackCoordinatorTests.swift:6` | 3 项：begin/claim/invalidate 的 token 与停止回调顺序 | 各实际页面停止源、麦克风释放、音频时序、硬件旧帧是否仍呈现 |
| `ios/RinaBoardTests/DraftStorageTests.swift:6` | 1 项：缺失草稿返回 nil，实际临时目录原子写入并替换 | 控制/文字草稿恢复、错误文件、写失败、应用中止、UI成功状态 |
| `ios/RinaBoardTests/FaceLibraryLocalTests.swift:7`、`:44` | 2 项：内存替身创建/重命名/删除/撤销、完整排序校验、保存失败时重命名不发布 | 真文件重启恢复、排序保存失败（测试名较宽，实际失败注入后执行的是重命名）、面板库 |
| `ios/Packages/RinaCore/Tests/RinaCoreTests/RinaLinkCodecTests.swift:5` | 6 项：编码回环、逐字节输入、粘包、垃圾前缀重同步、MORE 位、ERR JSON 解码 | BoardConnection MORE 聚合、GET_FACES 翻页/409重启、取消超时/连接恢复 |
| `ios/Packages/RinaCore/Tests/RinaCoreTests/RinaCommandTests.swift:73`、`:95`、`:112` | 热点凭据命令编码、清除编码、名称编码及24字节/CJK边界 | 真正配网、Keychain 成败、名称 persisted:false UI |
| `ios/RinaBoardUITests/RinaBoardUITests.swift:70` | 设置→连接→家庭 Wi-Fi 返回；Debug 四工作区入口内容存在 | 个人热点/AP操作、权限、日志收集/脱敏、维护确认行为 |

## 静态风险与证据

以下不是运行复现结论，优先安排用例验证。

1. **P1 跨设备配网可能继续操作新设备。** `ConnectionViewModel.swift:343`（个人热点流程）、`:449`（家庭网络）跨多个 await 发 CMD，未捕获/核对 connectionGeneration；`:487` 只匹配 profile 不匹配 SSID/设备。`BoardConnection.swift:494` 无输出 token 的普通 CMD 进入 commandPump 后没有入口代次校验。复现候选：A 配网第一条应答后暂停执行/延迟命令，连接 B，释放后续命令并让 B 发 home/hotspot 已关联事件；检查是否把模式/连接命令送给 B、把 A 流程显示成功。应在新 fake 集成测试精确控制时序；物理快速切换仅作补充。
2. **P2 过期连接调用可能误记成功。** `ConnectionViewModel.swift:240`、`:258`、`:281`、`:390` 忽略 `connect(using:)` 的 Bool，仅判断全局 connected。底层明确会在旧连接晚完成时返回 false（已有测试），此时全局可能是另一设备成功连接。复现候选：A 手动/AP连接延迟，B BLE连接成功后释放 A；检查 A 是否保存为最近成功、阶段是否误为 connected。
3. **P2 Keychain 写/删失败被 UI 当作成功。** `ConnectionViewModel.swift:399` 调用 save 后无条件置 hotspotPasswordIsSaved=true；`:422` delete 后同样清空 UI。`KeychainStore.swift:23`、`:47` 返回 Bool 被忽略。需注入 Security 失败，不能用真实账户碰运气；重启后检查提示是否与实际密码恢复一致。
4. **P2 脱敏正则可能只隐藏部分秘密。** `DebugViewModel.swift:413` 的正则以空白截断无引号值、以任何引号终止双引号值。候选输入 `Authorization: Bearer ACCEPTANCE_TOKEN` 与 JSON 字符串中包含转义双引号的 password；调用 log 后检查 logShareText，完整 token/密码不应残留。普通UI不一定产生此类内容，应先增加纯本机单元测试，禁止把真实凭据写入测试或报告。
5. **P2 请求序号耗尽无失败分支。** `BoardConnection.swift:405` 循环最多255次，仍可能返回已 pending/quarantined 的序号；`:463` 会覆盖 pending。通过替身并发挂起255请求后发第256个可复现候选，正常UI是否达到尚未证实。另`:419`只隔离2秒，协议未保证迟到应答在2秒内结束；需绕回压力测试才可判断可达影响。
6. **文档陈旧，不是产品缺陷。** `BoardConnection+Debug.swift:46` 仍声称 EV_LOG 被丢弃/开关禁用，但 `BoardConnection.swift:349` 已发出 log 事件且 DebugViewModel 有订阅实现。协议 §8 仍说以设备名预填热点，当前代码使用已确认 SSID。验收应以现实现与修复目标为准。

## 执行环境与记录规范

每例记录：App构建/固件版本、设备及iOS、连接对象（板A/板B与BLE标识）、传输、起止时间、结果、截图/日志路径。不要把HTTP端口80作为控制端口：RinaLink为TCP **5370**；HTTP只配网。BLE服务 `52494E41-0001-4C49-4E4B-000000000001`，RX …0002、TX …0003。物理链路必须用真机、烧录现有兼容固件的板、稳定供电；不要为验收擅自刷机。使用专用测试网络/表情副本；清除、重启与校准例只在明确安排的测试板执行。

默认直连AP为 **RinaChanBoard-V2 / rinachan / 192.168.1.14:5370**（`RinaLinkConstants.swift:19`）；若已改AP凭据，不可假定默认仍有效。个人热点为 iPhone 自己向板提供网络，不能让同一 iPhone 加入自己的SSID。家庭Wi-Fi与热点优先级需要控制可见网络：home可见时固件优先home。`config.h:17`关联超时15秒，`:18`重试60秒；App配网等待45秒，扫描等待8秒，需分别记录，不应把60秒重试误判成45秒内必定完成。

## Connection / Wi-Fi 详细用例

| ID | 前置 | 步骤 | 预期 | 状态 |
|---|---|---|---|---|
| CON-01 | 真机，蓝牙权限未决定，测试板通电 | 设置→连接→扫描；分别用干净授权状态允许/拒绝；再关闭蓝牙重试 | 允许后发现板；拒绝/关闭显示可行动错误；不无限扫描或虚报连接 | 未测试 |
| CON-02 | 两块板，默认或独特名称 | 扫描→连A→断开→连B；记录BLE标识与名称 | 每板身份稳定、无同名误选；设备信息与当前板一致 | 未测试 |
| CON-03 | 板已加入与手机同一测试LAN | Bonjour选板；再断开后手输板IP连接；断开后输不可达地址 | 两种有效路径均TCP5370可PING；错误地址失败且可重试 | 未测试 |
| CON-04 | 替身可挂起A connect、B即时成功 | 开始A连接→B连接成功→释放A；同时检查ConnectionViewModel与BoardStore | B保留；A返回失败且不保存A为成功、不覆盖阶段/名称 | 未测试 |
| CON-05 | 真机，分别建立BLE和TCP | 连通后拔掉测试板电源→恢复；手动断开另做一轮 | 非手动断线重连有状态；恢复后preview/status/power默认事件继续；手动断开不自行连接 | 未测试 |
| CON-06 | TCP连接稳定 | 前台无操作至少25秒，再PING、发送已知单点帧 | 5秒PING保活防止固件20秒闲置踢除；操作正常，无幽灵connected | 未测试 |
| WIFI-01 | 定位未授权的真机，已连接Wi-Fi | 首次进连接页观察；只有点读取当前Wi-Fi才授权；允许精确定位后读取 | 进入不自动请求；手机SSID单独显示，不把面板SSID或transport当手机SSID | 未测试 |
| WIFI-02 | 真机，可重置授权 | 分别拒绝定位、关闭精确定位、系统不返回SSID；每次点击读取 | 分别权限拒绝/需要精确定位/不可读取；不能断言“手机断网”；BLE仍可控制 | 未测试 |
| WIFI-03 | BLE连板，测试2.4GHz家庭网可见 | 板扫描→选SSID→输入密码→连接；等home已关联→点切换Wi-Fi→PING | 凭据、等待、板已加入、App TCP连接分阶段；板SSID/IP/profile正确 | 未测试 |
| WIFI-04 | BLE连板，故意错误的测试密码 | 家庭配网→等待45秒结果→修正密码重试 | 错误可见、无永久忙碌；重试成功；不显示App已TCP连接 | 未测试 |
| WIFI-05 | iPhone个人热点可用；home关闭或不可见；BLE连板 | iOS设置开启允许其他人加入，必要时最大兼容性；输入实际热点名/测试密码或选板扫描结果；配网 | profile=hotspot才通过；以板上报IP连接TCP；不使用通用iPhone作默认真实SSID | 未测试 |
| WIFI-06 | WIFI-05成功 | 杀进程重启进入热点页；更换SSID；切回原SSID；清除热点配置后再次重启 | 已确认SSID/密码按账户恢复；换SSID不串密码；清除本机密码与板配置一致 | 未测试 |
| WIFI-07 | 注入Keychain save/delete失败的测试替身 | 完成热点关联后触发保存失败；另做删除失败；重启/读存储对照UI | UI不得声称密码已保存/已删除；保留可重试信息 | 未测试 |
| WIFI-08 | 板BLE连通；默认AP配置已核实 | 设Wi-Fi模式ap→iPhone点板直连→允许系统加入→等待关联→PING | 确认加入后再TCP192.168.1.14:5370；阶段与实际传输一致 | 未测试 |
| WIFI-09 | 同WIFI-08 | 拒绝系统加入；再用错误/不可见AP；再正常重试 | 分别显示失败、可重试；不能仅配置安装完成就显示连接成功 | 未测试 |
| WIFI-10 | 替身或两块测试板 | A开始home/hotspot配网，等待中切B；B发送同profile但不同SSID事件 | A流程取消/失效；不操作B、不接受B事件完成A流程；参见静态风险1 | 未测试 |
| WIFI-11 | 两组测试凭据已保存 | home/hotspot都可见时重连；关闭home后重连；都关闭等AP与60秒重试；再恢复一网 | home优先，其次hotspot，皆无回退AP；分别记录扫描/15秒关联/60秒重试 | 未测试 |
| WIFI-12 | BLE连板 | 改名24 ASCII字节/8汉字→25字节/9汉字→清空；注入persisted:false | 合法生效，超限阻止，清空恢复默认；persisted:false明确重启会丢失 | 未测试 |

## Debug、持久化、跨模式与协议用例

| ID | 前置 | 步骤 | 预期 | 状态 |
|---|---|---|---|---|
| DBG-01 | 离线首次打开Debug；另有缺字段响应替身 | 查概览→连接并刷新→等31秒→断线 | 未采样/未知；输入不全不估算功率；显示采样时间/陈旧/断线前，不伪造0或健康 | 未测试 |
| DBG-02 | 真板有EV_LOG能力 | 开日志→制造可识别板端事件→按来源/级别/搜索过滤→冻结→产生新日志→恢复→关闭→断线重连 | 来源正确；冻结只冻结展示；恢复可见新增；关闭不继续订阅；断线状态清楚，重连默认log关闭可重新开启 | 未测试 |
| DBG-03 | 本机DebugViewModel测试 | 注入普通password、带空格Bearer、转义引号密码、嵌套JSON测试字符串→复制/分享日志 | 导出不残留任何测试秘密完整值或尾部；普通诊断文字保留；检查500条上限与120条显示 | 未测试 |
| DBG-04 | 真板正播放文字/演出 | 依次本机预览棋盘/边框/全黑→观察LED与当前输出；再明确发送棋盘 | 预览不改变板播放；发送才取得Debug输出，旧源停止且无迟到帧覆盖 | 未测试 |
| DBG-05 | 测试板，低亮度已设 | 全亮发送先取消再确认；维护重启/清用户表情先取消；清除用测试副本并确认 | 取消无板命令；确认才执行；默认表情保留；重启显示断连与恢复；校准重置另行记录原值 | 未测试 |
| DBG-06 | 替身回复ERR或ok:false | 原始命令无效JSON/未确认尝试发送；有效确认后分别拒绝/超时/成功 | 无效/未确认不发送；拒绝与传输失败区别可见；结果保留，不虚报成功 | 未测试 |
| DBG-07 | 替身STATUS/POWER含未知嵌套字段 | 刷新→原始数据搜索字段和值→查看原始JSON | 未识别字段仍可诊断；不被typed decode抹掉；缺字段不等于false | 未测试 |
| PERSIST-01 | 离线，实时同步关闭 | 控制画独特草稿；文字编辑未发送文本；后台再终止重启 | 两份草稿分别恢复；不自动发送，不改变本机/面板表情库，不标记发送成功 | 未测试 |
| PERSIST-02 | 可注入草稿文件损坏/写失败的测试环境 | 原有效草稿→写新内容失败→重启；另做损坏JSON恢复 | 原有效文件不被半写破坏；错误可见；恢复策略清楚；不静默宣称保存成功 | 未测试 |
| CROSS-01 | 真板，六源均可启动 | 分别手动/自动/文字/口型/演出/Debug启动后用另一源替换；每对至少一次，记录30个有向切换 | 当前输出唯一；旧源停止或按设计本地音频继续，旧帧/旧回应不覆盖新源 | 未测试 |
| CROSS-02 | 可延迟setFrame替身 | 挂起Debug帧A、排队帧B→手动新session→取消旧请求→发新帧C→释放旧应答 | A/B不发布，B不发送；新帧C继续完成；现有测试可作自动化基础 | 未测试 |
| CROSS-03 | 真机口型权限未决定 | 点开始→权限弹窗时离开口型→允许；另做后台和断连 | 不迟到启动麦克风；后台/离开/断连释放；恢复需明确开始 | 未测试 |
| CROSS-04 | 真机演出音频播放中 | 断开板→观察本地音频→恢复连接→明确重新同步 | 音频按设计继续；重连不擅自把旧演出覆盖新板；明确同步后恢复LED | 未测试 |
| PROTO-01 | 网络替身 | MORE分3段响应同seq/type，穿插EV_STATUS；另错type/错seq/ERR | 仅正确应答聚合一次；事件独立处理；错匹配不结束请求；ERR抛错 | 未测试 |
| PROTO-02 | GET_FACES替身含gen前缀 | 多页下载；第二页409→新gen从0重试；再一次409 | 不拼接两个文档；最多一次重启，第二次错误可见 | 未测试 |
| PROTO-03 | blob替身，分别scroll/bitmap/faces | 不同chunkMax上传；插400 expectedOffset、断连、取消；再发新任务 | raw scroll切片47字节整倍数；offset正确；有限重同步；取消无旧提交覆盖新会话 | 未测试 |
| PROTO-04 | 可控超时替身 | 挂255请求再第256；另超时后等超过2秒、绕回seq再投旧回复 | 无continuation丢失/新请求误完成；资源耗尽应受控失败；静态风险5待证实 | 未测试 |

## 新增自动化与其余建议（均未执行）

优先：ConnectionViewModel跨设备配网及过期connect返回；Debug脱敏/缺字段/冻结与拒绝统计；BoardConnection订阅恢复、MORE聚合、GET_FACES 409；真实草稿模型保存失败与重启恢复。替身要暴露明确的“命令已收到/连接已开始”门闩并await结束，避免仅sleep后猜测；保留XCTest，不为迁移而重写。Keychain与系统Wi-Fi权限需要可替换接口后再写失败注入测试，真机验收仍不可替代。其余建议已向主审回报，未改产品注入接口。后续获得主审授权，在 `ios/RinaBoardTests/AcceptanceRecoveryTests.swift` 添加4项非重复Debug回归：普通JSON密码脱敏、Bearer值完整脱敏、转义引号密码不泄露尾部、未知嵌套原始字段保留。Bearer与转义引号两项按静态实现预计会失败，必须以主审执行结果为准；没有用expectedFailure隐藏风险。测试目录是PBXFileSystemSynchronizedRootGroup（project.pbxproj:48、148），自动加入测试target，无项目文件更改。
