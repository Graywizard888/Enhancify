#!/data/data/com.termux/files/usr/bin/bash

CLI_DETECTION_FILE="$HOME/Enhancify/cli_detection.json"

Optimize_Libs() {
    if [[ "$CLI_RIPLIB_ANTISPLIT" == "on" ]]; then
        cli_arg_detector >/dev/null 2>&1
        
        if [[ -f "$CLI_DETECTION_FILE" ]]; then
            local riplib_support
            riplib_support=$(jq -r '.riplib' "$CLI_DETECTION_FILE")
            
            if [[ "$riplib_support" == "true" ]]; then
                notify info "Rip-Lib Support Detected\nOverrided to CLI based Riplib\nSkipping ..."
                sleep 2
                return 0
            else
                notify info "Critical !!\n$SOURCE Incompatible with CLI riplib\nOverride canceled"
                sleep 2
            fi
        fi
    fi

    local APP_DIR TEMP_DIR APP_PATH AAPT2_PATH
    
    notify info "Please Wait !!\nOptimizing Native Libraries ..."
    sleep 1

    APP_DIR="apps/$APP_NAME/$APP_VER"
    APP_PATH="$APP_DIR.apk"
    TEMP_DIR="$APP_DIR/temp"
    AAPT2_PATH="$HOME/Enhancify/bin/aapt2"

    if [[ ! -f "$AAPT2_PATH" ]]; then
        notify msg "aapt2 not found!\nOperation aborted."
        return 1
    fi

    notify info "Analyzing APK structure using aapt2..."
    sleep 1

    local LIBS_IN_APK
    LIBS_IN_APK=$("$AAPT2_PATH" dump badging "$APP_PATH" 2>/dev/null | \
        grep "^native-code:" | \
        sed "s/native-code: //g" | \
        tr -d "'" | \
        tr ' ' '\n' | \
        sort -u)

    if [[ -z "$LIBS_IN_APK" ]]; then
        notify msg "No native libraries found!\nOperation aborted!"
        return 1
    fi

    local ARCH_COUNT
    ARCH_COUNT=$(echo "$LIBS_IN_APK" | wc -l)

    if [[ $ARCH_COUNT -eq 1 ]] && echo "$LIBS_IN_APK" | grep -qx "$ARCH"; then
        notify info "Only device architecture ($ARCH) found.\nAPK Already Optimal!\nSkipping..."
        sleep 2
        return 0
    fi

    if ! echo "$LIBS_IN_APK" | grep -qx "$ARCH"; then
        local available_archs
        available_archs=$(echo "$LIBS_IN_APK" | tr '\n' ' ')
        notify msg "Device architecture ($ARCH) not found!\nAvailable: $available_archs\nOperation aborted."
        return 1
    fi

    rm -rf "$TEMP_DIR" 2>/dev/null
    mkdir -p "$TEMP_DIR"

    notify info "Extracting APK contents..."
    sleep 1

    if ! unzip -qq "$APP_PATH" -d "$TEMP_DIR"; then
        notify msg "Failed to unzip APK!\nOperation aborted."
        rm -rf "$TEMP_DIR"
        return 1
    fi

    notify info "Removing unused native libraries..."
    sleep 1

    if [[ -d "$TEMP_DIR/lib" ]]; then
        find "$TEMP_DIR/lib" -mindepth 1 -maxdepth 1 -type d \
            ! -name "$ARCH" -exec rm -rf {} + 2>/dev/null
    fi

    notify info "Removing old signature blocks..."
    sleep 1

    if [[ -d "$TEMP_DIR/META-INF" ]]; then
        find "$TEMP_DIR/META-INF" \( \
            -iname "*.SF" -o \
            -iname "*.MF" -o \
            -iname "*.RSA" -o \
            -iname "*.DSA" -o \
            -iname "*.EC" \
        \) -delete 2>/dev/null
    fi

    notify info "Rebuilding APK..."
    sleep 1

    local build_status=0
    (
        cd "$TEMP_DIR" || exit 1
        zip -qr -4 -X "../temp.apk" . || exit 2
    )
    build_status=$?

    if [[ $build_status -ne 0 ]] || [[ ! -f "$APP_DIR/temp.apk" ]]; then
        notify msg "Failed to repackage APK!\nOperation aborted."
        rm -rf "$TEMP_DIR" "$APP_DIR/temp.apk" 2>/dev/null
        return 1
    fi

    mv "$APP_DIR/temp.apk" "$APP_PATH"
    rm -rf "$TEMP_DIR"

    local new_size
    new_size=$(stat -c %s "$APP_PATH")
    setEnv "APP_SIZE" "$new_size" update "apps/$APP_NAME/.data"

    notify info "APK size optimized successfully!"
    sleep 1
    
    return 0
}
