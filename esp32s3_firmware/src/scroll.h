#pragma once


// 本文件播放固件端文字滚动帧并协调滚动状态；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明文字滚动、帧缓存或播放状态处理。
// 固件文字滚动渲染任务（Firmware scroll render task） 相关代码，维护 播放固件端文字滚动帧并协调滚动状态。
// ---------------------------------------------------------------------------

/**
 * 启动、渲染 startScrollRenderTask 相关逻辑，供 scroll 模块使用。
 * @brief 说明 文字滚动播放 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void startScrollRenderTask();

/**
 * 渲染 notifyScrollRenderTask 相关逻辑，供 scroll 模块使用。
 * @brief 说明 文字滚动播放 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void notifyScrollRenderTask();
