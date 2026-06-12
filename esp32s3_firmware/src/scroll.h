#pragma once


// 本文件播放固件端文字滚动帧并协调滚动状态；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 固件文字滚动渲染任务（Firmware scroll render task） 相关代码，维护 播放固件端文字滚动帧并协调滚动状态。
// ---------------------------------------------------------------------------

void startScrollRenderTask();

void notifyScrollRenderTask();
