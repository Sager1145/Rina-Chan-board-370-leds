#pragma once
#include <Arduino.h>


// 本文件采样电池/充电电压并发布电源状态；注释保留必要 English identifier，便于和代码/API 对照。
// 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
// 说明电源、电池、充电或 ADC 校准相关逻辑。
// 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
struct PowerStatus {
    float    vbat             = NAN;
    float    vcharge          = NAN;
    uint8_t  batteryPercent   = 0;
    bool     charging         = false;
    bool     batteryValid     = false;
    bool     chargeValid      = false;
    bool     batteryDisconnected = false;
    bool     batteryLowVoltageUnpowered = false;
    float    batteryCalibMaxV = NAN;
    float    batteryCalibMinV = NAN;
    bool     batteryCalibLoaded = false;
    bool     batteryCalibDirty  = false;
    uint16_t batteryAdcMv     = 0;
    uint16_t batteryPrevAdcMv = 0;
    uint16_t batteryDisconnectDropMv = 0;
    float    batteryLastInstantVbat = NAN;
    uint16_t chargeAdcMv      = 0;
    uint32_t lastBatteryMs    = 0;
    uint32_t lastChargeMs     = 0;
    uint32_t batteryDisconnectedSinceMs = 0;
    uint32_t lastBatteryDisconnectEventMs = 0;
    bool     batteryPrevAdcKnown = false;
    uint32_t lastCalibMaxMs   = 0;
    uint32_t lastCalibMinMs   = 0;
    uint32_t batteryCalibDirtySinceMs = 0;
    uint32_t lastWebSlowPublishMs = 0;
    float    webPublishedVbat     = NAN;
    float    webPublishedVcharge  = NAN;
    uint8_t  webPublishedBatteryPercent = 0;
    bool     webPublishedBatteryValid   = false;
    bool     webPublishedChargeValid    = false;
    bool     webPublishedCharging       = false;
    bool     webPublishedChargingKnown  = false;
    bool     webFastDirty               = true;
    bool     webSlowDirty               = true;
};

extern PowerStatus powerStatus;

/**
 * 初始化 initPowerMonitor 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void initPowerMonitor();

/**
 * 轮询服务 servicePowerMonitor 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param force 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void servicePowerMonitor(bool force = false);

/**
 * 重置 resetBatteryVoltageMinimum 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void resetBatteryVoltageMinimum();

/**
 * 重置 resetBatteryVoltageMaximum 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void resetBatteryVoltageMaximum();
