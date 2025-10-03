#!/usr/bin/bash

PKG_NAME="$1"
APP_NAME="$2"
EXPORTED_APK_NAME="$3"
STORAGE="$4"

if [ -z "$STORAGE" ]; then
    log() { echo "$1"; }
else
    log() { echo "- $1" >> "$STORAGE/rish_log.txt"; }
fi

log "Starting rish-install.sh for package: $PKG_NAME, app name: $APP_NAME, exported APK name: $EXPORTED_APK_NAME"
# Current user, it's usually 0, but can be different in some cases.
CURRENT_USER=$(rish -c "am get-current-user" 2>/dev/null | tr -d '\r\n' | xargs)
CURRENT_USER=${CURRENT_USER:-0}

# It's needed for pm install to have the APK in the /data/local/tmp/ directory
PATCHED_APP_PATH="/data/local/tmp/enhancify/$PKG_NAME.apk"
EXPORTED_APP_PATH="/storage/emulated/$CURRENT_USER/Enhancify/Patched/$EXPORTED_APK_NAME.apk"

# This is almost the same as the mouth.sh script from the su version.
if [ "$(rish -c "[ -d '/data/local/tmp/enhancify' ] && echo Exists || echo Missing")" == "Missing" ]; then
    rish -c "mkdir '/data/local/tmp/enhancify'"
    log "/data/local/tmp/enhancify created."
fi

# Named the same as the su version, maybe so people can choose to use su or rish, idk.
if [ "$(rish -c"[ -e $PATCHED_APP_PATH ] && echo Exists || echo Missing")" == "Exists" ]; then
    rish -c "rm $PATCHED_APP_PATH"
    log "Residual $PATCHED_APP_PATH deleted"
fi

log "Moving exported APK to /data/local/tmp/enhancify..."
rish -c "mv -f $EXPORTED_APP_PATH $PATCHED_APP_PATH"

if [ "$(rish -c "[ -e $PATCHED_APP_PATH ] && echo Exists || echo Missing")" == "Missing" ]; then
    log "Failed to move patched APK to $PATCHED_APP_PATH"
    exit 1
fi

CMD_RISH="pm install -r --user current $PATCHED_APP_PATH"

# We execute the install command using rish
OUTPUT=$(rish -c "$CMD_RISH" 2>&1)
log "Install command: $CMD_RISH"
log "Install output: $OUTPUT"

# We check the output for success or failure
if echo "$OUTPUT" | grep -q "^Success"; then
    log "Install succeeded."
    rish -c "rm -f $PATCHED_APP_PATH"  # Clean up the temporary APK
    exit 0
elif [ "$(rish -c "pm list packages --user current | grep -q $PKG_NAME && echo Installed")" == "Installed" ]; then
    log "Install succeeded, but output was not 'Success'."
    rish -c "rm -f $PATCHED_APP_PATH"  # Clean up the temporary APK
    exit 0
else
    # Sometimes the output is not "Success" but still the app is installed, so we check for that.
    log "Install failed. Moving APK back to original location."
    rish -c "mv -f $PATCHED_APP_PATH $EXPORTED_APP_PATH"  # Move the APK back to the original location
    exit 1
fi