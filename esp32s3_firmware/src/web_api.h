#pragma once


// 本文件注册 SoftAP、DNS captive portal 和 HTTP API 路由；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
// HTTP 服务器生命周期（HTTP server lifecycle） 相关代码，维护 注册 SoftAP、DNS captive portal 和 HTTP API 路由。
// ---------------------------------------------------------------------------

/**
 * 启动 startAccessPoint 相关逻辑，供 web_api 模块使用。
 * @brief 说明 SoftAP、DNS 和 HTTP API 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void startAccessPoint();

/**
 * 启动 startWebServer 相关逻辑，供 web_api 模块使用。
 * @brief 说明 SoftAP、DNS 和 HTTP API 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void startWebServer();

/**
 * 围绕 webServerTick 处理本模块的核心流程，供 web_api 模块使用。
 * @brief 说明 SoftAP、DNS 和 HTTP API 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void webServerTick();

/**
 * 围绕 showFilesystemErrorPattern 处理本模块的核心流程，供 web_api 模块使用。
 * @brief 说明 SoftAP、DNS 和 HTTP API 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void showFilesystemErrorPattern();
