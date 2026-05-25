#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Mode helpers
// ---------------------------------------------------------------------------

/**
 * @brief Check whether runtime mode is auto.
 * @param None.
 * @return true when runtimeState().mode is "auto".
 */
bool isAutoMode();

/**
 * @brief Normalize mode aliases from UI/API/settings into firmware strings.
 * @param input Raw mode text.
 * @return "auto", "manual", or the trimmed fallback.
 */
String normalizedMode(const char* input);

/**
 * @brief Set playback mode and optionally persist it.
 * @param input Requested mode text.
 * @param persistSettings true to save runtime settings to LittleFS.
 * @return true when input is a supported mode.
 */
bool setMode(const char* input, bool persistSettings = true);

/**
 * @brief Set the auto-advance interval.
 * @param ms Requested interval in milliseconds.
 * @param persistSettings true to save runtime settings to LittleFS.
 * @return None.
 */
void setAutoInterval(uint32_t ms, bool persistSettings = true);

// ---------------------------------------------------------------------------
// Face apply helpers
// ---------------------------------------------------------------------------

/**
 * @brief Apply the saved face at the given index and schedule a render.
 * @param index Saved-face index; wraps by available count.
 * @param reason Diagnostic render reason.
 * @param playback Playback label to store, or nullptr to preserve.
 * @return true when a face was applied.
 */
bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

/**
 * @brief Apply a face at current index plus a signed delta.
 * @param delta Signed offset with wrapping.
 * @param reason Diagnostic render reason.
 * @return true when a face was applied.
 */
bool applyRelativeSavedFace(int8_t delta, const String& reason);

/**
 * @brief Apply the currently selected saved face for manual or auto mode.
 * @param reason Diagnostic render reason.
 * @param autoMode true to label playback as auto_saved_face.
 * @return true when a face was applied.
 */
bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode);

/**
 * @brief Toggle manual/auto mode from the B3/M-A action.
 * @param source Source prefix used in reason strings.
 * @return true when the mode toggle was accepted.
 */
bool toggleModeFromButtonAction(const String& source);

// ---------------------------------------------------------------------------
// Scroll stop / startup face restore
// ---------------------------------------------------------------------------

/**
 * @brief Cancel a pending deferred saved-face restore.
 * @param None.
 * @return None.
 */
void cancelDeferredFaceRestore();

/**
 * @brief Schedule current saved-face restore after blank-frame latch time.
 * @param autoMode true to restore auto playback semantics.
 * @param reason Diagnostic render reason for the restore.
 * @return None.
 */
void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason);

/**
 * @brief Service deferred saved-face restore from loop().
 * @param None.
 * @return None.
 */
void serviceDeferredFaceRestore();

// ---------------------------------------------------------------------------
// Scroll lifecycle
// ---------------------------------------------------------------------------

/**
 * @brief Stop the firmware scroll engine.
 * @param restoreAuto true to restore auto mode when scroll started from auto.
 * @param clearDisplay true to blank display before restoring the default face.
 * @return None.
 */
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false);

/**
 * @brief Arm and start firmware scroll from cached frame bits.
 * @param intervalMs Requested frame interval in milliseconds.
 * @return None.
 */
void startFirmwareScroll(uint16_t intervalMs);

/**
 * @brief Set the user-controlled firmware-scroll pause flag.
 * @param paused Requested pause state.
 * @return true when effective scroll state changed.
 */
bool setFirmwareScrollUserPaused(bool paused);

/**
 * @brief Set the temporary system-controlled scroll pause flag.
 * @param paused Requested pause state.
 * @return true when effective scroll state changed.
 */
bool setFirmwareScrollSystemPaused(bool paused);

// ---------------------------------------------------------------------------
// Playback state query
// ---------------------------------------------------------------------------

/**
 * @brief Check whether a playback label represents firmware scroll.
 * @param playback Runtime playback label.
 * @return true for scroll labels.
 */
bool isScrollPlayback(const String& playback);

/**
 * @brief Check whether current playback should be interrupted before face display.
 * @param None.
 * @return true for scroll/custom/debug/non-face activity.
 */
bool playbackIsNonFaceActivity();

// ---------------------------------------------------------------------------
// Auto-playback  (called each loop() iteration)
// ---------------------------------------------------------------------------

/**
 * @brief Advance auto saved-face playback when its interval elapses.
 * @param None.
 * @return None.
 */
void serviceAutoPlayback();
