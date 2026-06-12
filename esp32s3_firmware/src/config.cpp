#include "config.h"


// 本文件集中声明硬件引脚、LED 矩阵、时序和默认运行参数；注释保留必要 English identifier，便于和代码/API 对照。
// 说明 硬件、矩阵和时序配置 中当前代码块的职责和维护约束。
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 说明 硬件、矩阵和时序配置 中当前代码块的职责和维护约束。
const IPAddress AP_IP_ADDR(192, 168, 1, 14);
const IPAddress AP_GATEWAY_ADDR(192, 168, 1, 14);
const IPAddress AP_SUBNET_MASK(255, 255, 255, 0);
