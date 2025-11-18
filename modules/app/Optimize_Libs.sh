Optimize_Libs() {
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

    notify info "Analyzing APK structure Using aapt2..."
    sleep 1

    local LIBS_IN_APK
    LIBS_IN_APK=$("$AAPT2_PATH" dump badging "$APP_PATH" 2>/dev/null | grep "^native-code:" | sed "s/native-code: //g" | tr -d "'" | tr ' ' '\n' | sort -u)

    if [[ -z "$LIBS_IN_APK" ]]; then
        notify info "No native libraries found!\nOperation aborted !"
        sleep 1
        return 1
    fi

    local ARCH_COUNT
    ARCH_COUNT=$(echo "$LIBS_IN_APK" | wc -l)

    if [[ $ARCH_COUNT -eq 1 ]] && echo "$LIBS_IN_APK" | grep -q "^${ARCH}$"; then
        notify info "Only device architecture ($ARCH) found.\nApk Arch Already In Optimal State!\nSkipping..."
        sleep 2
        return 0
    fi

    if ! echo "$LIBS_IN_APK" | grep -q "^${ARCH}$"; then
        notify msg "Device architecture ($ARCH) not found in APK!\nAvailable: $(echo $LIBS_IN_APK | tr '\n' ' ')\nOperation aborted."
        return 1
    fi

    rm -rf "$TEMP_DIR" &>/dev/null
    mkdir -p "$TEMP_DIR"

    notify info "Extracting apk file contents..."
    if ! unzip -qq "$APP_PATH" -d "$TEMP_DIR"; then
        notify msg "Failed to unzip APK file!\nOperation aborted."
        rm -rf "$TEMP_DIR"
        return 1
    fi

    notify info "Removing unused libs..."
    find "$TEMP_DIR/lib" -mindepth 1 -maxdepth 1 -type d \
        ! -name "$ARCH" -exec rm -rf {} + &>/dev/null

    notify info "Removing old signature blocks..."
    if [[ -d "$TEMP_DIR/META-INF" ]]; then
        find "$TEMP_DIR/META-INF" \( -iname "*.SF" -o -iname "*.MF" -o -iname "*.RSA" -o -iname "*.DSA" -o -iname "*.EC" \) -delete
    fi

    notify info "Building apk..."
    (
        cd "$TEMP_DIR" || exit 1
        if ! zip -qr -0 -X ../temp.apk ./*; then
            notify msg "Failed to repackage APK!\nOperation aborted."
            cd .. && rm -rf "$TEMP_DIR" "temp.apk"
            exit 2
        fi
    )

    if [[ $? -eq 2 ]] || [[ ! -f "$APP_DIR/temp.apk" ]]; then
        return 1
    fi

    mv "$APP_DIR/temp.apk" "$APP_PATH"
    rm -rf "$TEMP_DIR"

    setEnv "APP_SIZE" "$(stat -c %s "$APP_PATH")" update "apps/$APP_NAME/.data"
    notify info "App Size optimized successfully!"
    sleep 1
}
