#pragma once


// 本文件注册 SoftAP、DNS captive portal 和 HTTP API 路由；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// HTTP 服务器生命周期（HTTP server lifecycle） 相关代码，维护 注册 SoftAP、DNS captive portal 和 HTTP API 路由。
// ---------------------------------------------------------------------------

void startAccessPoint();

void startWebServer();

void webServerTick();

void showFilesystemErrorPattern();
