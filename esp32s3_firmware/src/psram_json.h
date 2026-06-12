#pragma once

#include <ArduinoJson.h>
#include <esp_heap_caps.h>


// 本文件为 ArduinoJson 文档选择 PSRAM 优先的内存分配器；注释保留必要 English identifier，便于和代码/API 对照。
struct SpiRamAllocator {
    /**
 * 围绕 allocate 处理本模块的核心流程，供 psram_json 模块使用。
     * @brief 说明 PSRAM 优先的 JSON 内存分配 中当前函数或声明的用途。
     * @param size 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    void* allocate(size_t size) {
        void* ptr = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_malloc(size, MALLOC_CAP_8BIT);
    }

    /**
 * 围绕 deallocate 处理本模块的核心流程，供 psram_json 模块使用。
     * @brief 说明 PSRAM 优先的 JSON 内存分配 中当前函数或声明的用途。
     * @param pointer 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    void deallocate(void* pointer) {
        heap_caps_free(pointer);
    }

    /**
 * 围绕 reallocate 处理本模块的核心流程，供 psram_json 模块使用。
     * @brief 说明 PSRAM 优先的 JSON 内存分配 中当前函数或声明的用途。
     * @param pointer 调用方传入或接收的参数，含义以函数签名为准。
     * @param newSize 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    void* reallocate(void* pointer, size_t newSize) {
        void* ptr = heap_caps_realloc(pointer, newSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_realloc(pointer, newSize, MALLOC_CAP_8BIT);
    }
};

using PsramJsonDocument = BasicJsonDocument<SpiRamAllocator>;
