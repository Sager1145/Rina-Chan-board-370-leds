#pragma once

// ---------------------------------------------------------------------------
// HTTP server lifecycle
// ---------------------------------------------------------------------------

/**
 * @brief Start the ESP32 SoftAP and captive DNS service.
 * @param None.
 * @return None.
 */
void startAccessPoint();

/**
 * @brief Register all HTTP routes and start the synchronous WebServer.
 * @param None.
 * @return None.
 */
void startWebServer();

/**
 * @brief Service pending DNS and HTTP work from loop().
 * @param None.
 * @return None.
 */
void webServerTick();

/**
 * @brief Render a red LED diagnostic pattern when LittleFS failed to mount.
 * @param None.
 * @return None.
 */
void showFilesystemErrorPattern();
