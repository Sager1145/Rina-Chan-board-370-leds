# 保存功能验收记录

日期：2026-10-15。本轮测试现有实现并提出设计，未实施板端唯一存储改造，未提交、推送或烧录新固件。

## 实机结果

测试板 A：80B54EF48E09；B：80B54EF74801。两板测试前各有 11 张默认表情。

- A 新增副本、重命名、读回；B 新增、重命名、覆盖自定义像素、部件构造后另存。B 自定义图为 330 灯，部件图为 8 灯，完整 47 字节读回正确。两板列表隔离。
- 串口 btn B1/B2 与 GPIO 共用 runButtonAction。遍历 A 的 12 项、B 的 13 项并验证回绕、前后切换及每项亮灯数；B3 开启固件自动切换，覆盖两板全部项目，结束后恢复手动模式。用户实际按 B 的 B1/B2，确认图案符合预期。
- 两板正常硬件复位后，新增项的 ID、名称、顺序、完整像素及部件调用信息保持一致。A 的新增副本在重连导出后少了 App 导出字段 updatedAt，因此不声称整个导出 JSON 字节一致。
- 已逐项删除本轮 3 个 QA 临时表情。最终读回与测试前的 11 个表情逐字段一致。两板最终 faceIndex=7、lit=34、manual/idle、brightness=50、color=#f971d4、intervalMs=3000、refreshFail=0。
- 当前 App 离线仍展示本机保存库，不符合用户新要求；这是待改行为。

串口触发入口已经存在于 esp32s3_firmware/src/serial_console.cpp，GPIO 入口在 buttons.cpp。复用现有命令，不增加第二套按钮逻辑。串口测试覆盖业务动作，不覆盖按键电气消抖和长按时序。

## 自动验证

| 范围 | 结果 |
|---|---|
| App 保存、连接、草稿等既有相关测试 | 97 项通过 |
| 新增的临时边界探针 | 2 项失败，确认下述缺陷 |
| RinaCore 全量 | 378 项，11 跳过，0 失败 |
| 固件 protocol_selftest | 23 个测试入口通过，含保存故障注入 |

探针一：新建得到 ACK 后 GET_FACES 失败，保存调用仍返回成功且没有目标 ID，再保存可能再次发送无 ID 创建。

探针二：外部只重命名后 reload，旧编辑稿可能把读到的新名字误当作本会话重命名基线，静默覆盖外部修改。

临时探针仅用于复现，已移出产品测试目录，保存在 /tmp/rina-save-review/SaveFlowAuditProbeTests.swift。尚未修复这两个缺陷，不能将本轮结果称为全部通过。

## 证据与限制

原始证据目录：/tmp/rina-save-review。主要文件：ios-save-tests.log、ios-save-edge-probes.log、core.log、firmware-host.log、cycle-test.log、reboot-test-corrected.log、A-final-status.log、B-final-status.log，以及每板 before/created/reboot/after 四份 JSON。

现有安装的 macOS App 用于实机操作。当前源码的 Catalyst 编译被 FoldedControlCenterToolbar.swift 的 toolbarVerticalCompressionBehavior 可用性错误阻塞；源码保存行为由 iOS Simulator 测试验证，不能将已安装客户端等同于当前 main 构建。

初次复位探针因 CH343 的 DTR/RTS 时序进入 ROM 下载模式；修正 GPIO0 释放时序后两板均正常启动，未擦写闪存。没有实施写入瞬间的真实断电；正常重启与主机故障注入不能替代该测试。没有双真实客户端并发写入测试。

设计见同目录 2026-10-15-board-owned-faces-design.zh-CN.md：板端唯一正式库、离线隐藏列表、独立可恢复草稿、版本化部件引用、47 字节自定义像素载荷、兼容读回投影、固定 ID 与条件写入、保存结果读回确认。
