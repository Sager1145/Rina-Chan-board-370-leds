#pragma once

// ---------------------------------------------------------------------------
// HTTP server lifecycle
// ---------------------------------------------------------------------------

// Start the Wi-Fi Access Point.
void startAccessPoint();

// Register all routes and start the WebServer.
void startWebServer();

// Call every loop() iteration to service pending HTTP requests.
void webServerTick();

// Light the first 12 LEDs in red to indicate a LittleFS mount failure.
// Called from setup() before the web server is available.
void showFilesystemErrorPattern();
