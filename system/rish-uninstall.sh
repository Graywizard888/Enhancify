#!/usr/bin/bash

PKG_NAME="$1"
UNINSTALL_FROM_ALL_USERS="$2"
STORAGE="$3"

if [ -z "$STORAGE" ]; then
    log() { echo "$1"; }
else
    log() { echo "- $1" >> "$STORAGE/rish_log.txt"; }
fi

# Android 17 (dev preview) with the thedjchi Shizuku fork prints an
# "Entering shell..." banner (to stdout, and possibly stderr) before every
# command. It is emitted via println(), so it is always on its own line and
# the real command output follows it. We delete that banner line, and also
# strip the banner as a prefix if anything follows it on the same line, so
# captured output (e.g. `$(rish -c "...")`) is never polluted and real
# success/error output keeps priority. The real rish exit code is preserved.
rish() {
    local _rish_err _rish_rc _rish_del _rish_strip
    _rish_del='/^[[:space:]]*Entering shell\.\.*[[:space:]]*$/d'
    _rish_strip='s/^[[:space:]]*Entering shell\.\.*[[:space:]]*//'
    _rish_err=$(mktemp) 2>/dev/null
    if [ -n "$_rish_err" ]; then
        command rish "$@" 2>"$_rish_err" | sed -e "$_rish_del" -e "$_rish_strip"
        _rish_rc=${PIPESTATUS[0]}
        sed -e "$_rish_del" -e "$_rish_strip" "$_rish_err" >&2
        rm -f "$_rish_err"
    else
        command rish "$@" | sed -e "$_rish_del" -e "$_rish_strip"
        _rish_rc=${PIPESTATUS[0]}
    fi
    return "$_rish_rc"
}

# Uninstall command
if [ "$UNINSTALL_FROM_ALL_USERS" = true ]; then
    CMD_RISH="pm uninstall --user all $PKG_NAME"
else
    CMD_RISH="pm uninstall --user current $PKG_NAME"
fi

# Execute the uninstall command using rish
OUTPUT=$(rish -c "$CMD_RISH" 2>&1)
log "Uninstall command: $CMD_RISH"
log "Uninstall output: $OUTPUT"

# Check the output for success or failure
if echo "$OUTPUT" | grep -q "^Success"; then
    log "Uninstall succeeded."
    exit 0
else
    log "Uninstall failed or with empty output, checking if package is still present."
    if [ "$UNINSTALL_FROM_ALL_USERS" == true ]; then
        if rish -c "dumpsys package $PKG_NAME" 2>&1 | grep -q "Unable to find package"; then
            log "Package $PKG_NAME no longer present in any user."
            exit 0
        else
            log "Package $PKG_NAME still present in another user."
            exit 1
        fi
    else
        if rish -c "pm list packages --user current" 2>&1 | grep -q "package:$PKG_NAME"; then
            log "Package $PKG_NAME still present for current user."
            exit 1
        else
            log "Package $PKG_NAME fully uninstalled."
            exit 0
        fi
    fi
fi