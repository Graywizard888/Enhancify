#!/usr/bin/bash

PKG_NAME="$1"
APP_NAME="$2"
EXPORTED_APK_NAME="$3"
STORAGE="$4"
INSTALL_TYPE_OVERRIDE="$5"

# Logging function - writes to file if STORAGE is provided, otherwise to stdout
if [ -z "$STORAGE" ]; then
    log() { echo "$1"; }
else
    log() { echo "- $1" >> "$STORAGE/rish_log.txt"; }
fi

log "Starting rish-install.sh for package: $PKG_NAME, app name: $APP_NAME, exported APK name: $EXPORTED_APK_NAME"

# Get current user (usually 0, but can vary)
CURRENT_USER=$(rish -c "am get-current-user" 2>/dev/null | tr -d '\r\n' | xargs)
CURRENT_USER=${CURRENT_USER:-0}
log "Current user: $CURRENT_USER"

# Define paths
PATCHED_APP_PATH="/data/local/tmp/enhancify/$PKG_NAME.apk"
EXPORTED_APP_PATH="/storage/emulated/$CURRENT_USER/Enhancify/Patched/$EXPORTED_APK_NAME.apk"

# Detect install type or use override
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

# Write install type to file for main script to read
if [ -n "$STORAGE" ]; then
    echo "$INSTALL_TYPE" > "$STORAGE/install_type.txt"
    log "Install type written to $STORAGE/install_type.txt: $INSTALL_TYPE"
fi

# Create working directory if it doesn't exist
if [ "$(rish -c "[ -d '/data/local/tmp/enhancify' ] && echo Exists || echo Missing")" == "Missing" ]; then
    rish -c "mkdir '/data/local/tmp/enhancify'"
    log "/data/local/tmp/enhancify created."
fi

# Remove any residual APK from previous installations
if [ "$(rish -c "[ -e $PATCHED_APP_PATH ] && echo Exists || echo Missing")" == "Exists" ]; then
    rish -c "rm $PATCHED_APP_PATH"
    log "Residual $PATCHED_APP_PATH deleted"
fi

# Move APK to temporary installation directory
log "Moving exported APK to /data/local/tmp/enhancify..."
rish -c "mv -f $EXPORTED_APP_PATH $PATCHED_APP_PATH"

# Verify the move was successful
if [ "$(rish -c "[ -e $PATCHED_APP_PATH ] && echo Exists || echo Missing")" == "Missing" ]; then
    log "Failed to move patched APK to $PATCHED_APP_PATH"
    exit 1
fi

# Prepare and execute installation command
CMD_RISH="pm install -r -i com.android.vending --user current $PATCHED_APP_PATH"
OUTPUT=$(rish -c "$CMD_RISH" 2>&1)
log "Install command: $CMD_RISH"
log "Install output: $OUTPUT"

# Check installation result and handle accordingly
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
