Optimize_Libs() {
    local APP_DIR TEMP_DIR APP_PATH
    notify info "Please Wait !!\nOptimizing Native Libraries ..."
sleep 1

    APP_DIR="apps/$APP_NAME/$APP_VER"
    APP_PATH="$APP_DIR.apk"
    TEMP_DIR="$APP_DIR/temp"

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
    rm -rf "$TEMP_DIR/META-INF"

    notify info "Building apk..."
    (
        cd "$TEMP_DIR" || exit 1
        if ! zip -qr -0 -X ../temp.apk ./*; then
            notify msg "Failed to repackage APK!\nOperation aborted."
            cd .. && rm -rf "$TEMP_DIR" "temp.apk"
            exit 2
        fi
    )

    # Handle packaging result
    if [[ $? -eq 2 ]] || [[ ! -f "$APP_DIR/temp.apk" ]]; then
        return 1
    fi

    # Replace original APK
    mv "$APP_DIR/temp.apk" "$APP_PATH"
    rm -rf "$TEMP_DIR"

    # Update environment file
    setEnv "APP_SIZE" "$(stat -c %s "$APP_PATH")" update "apps/$APP_NAME/.data"
    notify info "App Size optimized successfully!"

sleep 1
}
