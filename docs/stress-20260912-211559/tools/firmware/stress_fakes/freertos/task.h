#pragma once
#include "FreeRTOS.h"
#include <Arduino.h>
// vTaskDelay advances the fake clock; ulTaskNotifyTake calls a harness hook.
inline void vTaskDelay(uint32_t ticks) { delay(ticks); }
extern void (*g_fakeNotifyTakeHook)(uint32_t ticks);
inline uint32_t ulTaskNotifyTake(int, uint32_t ticks) { if (g_fakeNotifyTakeHook) g_fakeNotifyTakeHook(ticks); else delay(ticks); return 0; }
inline void xTaskNotifyGive(TaskHandle_t) {}
inline BaseType_t xTaskCreatePinnedToCore(void (*)(void*), const char*, uint32_t, void*, uint32_t, TaskHandle_t* h, int) { if (h) *h = nullptr; return pdPASS; }
