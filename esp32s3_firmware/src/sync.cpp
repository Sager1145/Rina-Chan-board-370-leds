#include "sync.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>


// 本文件封装 FreeRTOS mutex 和跨核心同步保护；注释保留必要 English identifier，便于和代码/API 对照。
static SemaphoreHandle_t sFrameMutex       = nullptr;
static SemaphoreHandle_t sScrollMutex      = nullptr;
static SemaphoreHandle_t sHardwareBusMutex = nullptr;

// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
static void lockDomain(SyncDomain domain) {
    switch (domain) {
        case SyncDomain::Frame:
            lockFrame();
            break;
        case SyncDomain::Scroll:
            lockScroll();
            break;
        case SyncDomain::HardwareBus:
            lockHardwareBus();
            break;
    }
}

// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
static void unlockDomain(SyncDomain domain) {
    switch (domain) {
        case SyncDomain::Frame:
            unlockFrame();
            break;
        case SyncDomain::Scroll:
            unlockScroll();
            break;
        case SyncDomain::HardwareBus:
            unlockHardwareBus();
            break;
    }
}

ScopedLock::ScopedLock(SyncDomain domain) : domain_(domain) {
    lockDomain(domain_);
    locked_ = true;
}

ScopedLock::~ScopedLock() {
    if (locked_) {
        unlockDomain(domain_);
    }
}

bool initSyncPrimitives() {
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
    if (!sFrameMutex) sFrameMutex = xSemaphoreCreateMutex();
    if (!sScrollMutex) sScrollMutex = xSemaphoreCreateMutex();
    if (!sHardwareBusMutex) sHardwareBusMutex = xSemaphoreCreateMutex();
    return sFrameMutex && sScrollMutex && sHardwareBusMutex;
}

void lockFrame() {
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    if (sFrameMutex) xSemaphoreTake(sFrameMutex, portMAX_DELAY);
}

void unlockFrame() {
    if (sFrameMutex) xSemaphoreGive(sFrameMutex);
}

void lockScroll() {
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
    if (sScrollMutex) xSemaphoreTake(sScrollMutex, portMAX_DELAY);
}

void unlockScroll() {
    if (sScrollMutex) xSemaphoreGive(sScrollMutex);
}

void lockHardwareBus() {
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
}
