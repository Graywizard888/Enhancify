#!/usr/bin/bash

PKG_NAME="$1"
APP_NAME="$2"
EXPORTED_APK_NAME="$3"
STORAGE="$4"
INSTALL_TYPE_OVERRIDE="$5"

if [ -z "$STORAGE" ]; then
    log() { echo "$1"; }
else
    log() { echo "- $1" >> "$STORAGE/rish_log.txt"; }
fi

log "Starting rish-install.sh for package: $PKG_NAME, app name: $APP_NAME, exported APK name: $EXPORTED_APK_NAME"

CURRENT_USER=$(rish -c "am get-current-user" 2>/dev/null | tr -d '\r\n' | xargs)
CURRENT_USER=${CURRENT_USER:-0}
log "Current user: $CURRENT_USER"

CONFIG_FILE="$HOME/Enhancify/.config"
SKIP_VERIFICATION="off"
BYPASS_LOW_TARGET_SDK_BLOCK="off"

if [ -f "$CONFIG_FILE" ]; then
    log "Config file found at: $CONFIG_FILE"

    SKIP_VERIFICATION=$(grep "^SKIP_VERIFICATION=" "$CONFIG_FILE" | cut -d"'" -f2)
    BYPASS_LOW_TARGET_SDK_BLOCK=$(grep "^BYPASS_LOW_TARGET_SDK_BLOCK=" "$CONFIG_FILE" | cut -d"'" -f2)

    SKIP_VERIFICATION=${SKIP_VERIFICATION:-off}
    BYPASS_LOW_TARGET_SDK_BLOCK=${BYPASS_LOW_TARGET_SDK_BLOCK:-off}

    log "Config: SKIP_VERIFICATION='$SKIP_VERIFICATION'"
    log "Config: BYPASS_LOW_TARGET_SDK_BLOCK='$BYPASS_LOW_TARGET_SDK_BLOCK'"
else
    log "Config file not found at: $CONFIG_FILE (using defaults)"
    log "Config: SKIP_VERIFICATION='$SKIP_VERIFICATION'"
    log "Config: BYPASS_LOW_TARGET_SDK_BLOCK='$BYPASS_LOW_TARGET_SDK_BLOCK'"
fi

PATCHED_APP_PATH="/data/local/tmp/enhancify/$PKG_NAME.apk"
EXPORTED_APP_PATH="/storage/emulated/$CURRENT_USER/Enhancify/Patched/$EXPORTED_APK_NAME.apk"

if [ -n "$INSTALL_TYPE_OVERRIDE" ]; then
    INSTALL_TYPE="$INSTALL_TYPE_OVERRIDE"
    log "Install type override provided: $INSTALL_TYPE"
else
    INSTALL_TYPE="new"
    if [ "$(rish -c "pm list packages --user current | grep -q $PKG_NAME && echo Installed")" == "Installed" ]; then
        INSTALL_TYPE="update"
        CURRENT_VERSION=$(rish -c "dumpsys package $PKG_NAME" | sed -n '/versionName/s/.*=//p' | sed -n '1p')
        log "Existing installation detected (v$CURRENT_VERSION) - this will be an UPDATE"
    else
        log "No existing installation detected - this will be a NEW INSTALL"
    fi
fi

if [ -n "$STORAGE" ]; then
    echo "$INSTALL_TYPE" > "$STORAGE/install_type.txt"
    log "Install type written to $STORAGE/install_type.txt: $INSTALL_TYPE"
fi

if [ "$(rish -c "[ -d '/data/local/tmp/enhancify' ] && echo Exists || echo Missing")" == "Missing" ]; then
    rish -c "mkdir '/data/local/tmp/enhancify'"
    log "/data/local/tmp/enhancify created."
fi

if [ "$(rish -c "[ -e $PATCHED_APP_PATH ] && echo Exists || echo Missing")" == "Exists" ]; then
    rish -c "rm $PATCHED_APP_PATH"
    log "Residual $PATCHED_APP_PATH deleted"
fi

log "Moving exported APK to /data/local/tmp/enhancify..."
rish -c "mv -f $EXPORTED_APP_PATH $PATCHED_APP_PATH"

if [ "$(rish -c "[ -e $PATCHED_APP_PATH ] && echo Exists || echo Missing")" == "Missing" ]; then
    log "Failed to move patched APK to $PATCHED_APP_PATH"
    exit 1
fi

INSTALL_FLAGS=""

if [ "$SKIP_VERIFICATION" == "on" ]; then
    INSTALL_FLAGS="$INSTALL_FLAGS --skip-verification"
    log "Adding flag: --skip-verification"
fi

if [ "$BYPASS_LOW_TARGET_SDK_BLOCK" == "on" ]; then
    INSTALL_FLAGS="$INSTALL_FLAGS --bypass-low-target-sdk-block"
    log "Adding flag: --bypass-low-target-sdk-block"
fi

CMD_RISH="pm install -r -i com.android.vending$INSTALL_FLAGS --user current $PATCHED_APP_PATH"
OUTPUT=$(rish -c "$CMD_RISH" 2>&1)
log "Install command: $CMD_RISH"
log "Install output: $OUTPUT"

if echo "$OUTPUT" | grep -q "^Success"; then
    log "Install succeeded."
    rish -c "rm -f $PATCHED_APP_PATH"
    exit 0
elif [ "$(rish -c "pm list packages --user current | grep -q $PKG_NAME && echo Installed")" == "Installed" ]; then
    log "Install succeeded, but output was not 'Success'."
    rish -c "rm -f $PATCHED_APP_PATH"
    exit 0
else
    log "Install failed. Moving APK back to original location."
    rish -c "mv -f $PATCHED_APP_PATH $EXPORTED_APP_PATH"
    exit 1
fi
