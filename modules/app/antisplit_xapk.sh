antisplit_xapk() {
    local APP_DIR TEMP_DIR MANIFEST BASE_APK MERGE_DIR
    local lang_names=() lang_name code msg attempt
    declare -A SPLIT_MAP

    # Dependency check
    [[ ! -f "bin/APKEditor.jar" ]] && {
        notify msg "APKEditor missing! Install first"
        return 1
    }

    notify info "Processing XAPK file... [10%]"

    APP_DIR="apps/$APP_NAME/$APP_VER"
    TEMP_DIR="$APP_DIR/temp"
    mkdir -p "$TEMP_DIR"

sleep 1

    # Retry unzip (up to 3 attempts)
    for attempt in {1..3}; do
        notify info "Extracting package... [$((attempt*15))%]"
        if unzip -qqo "apps/$APP_NAME/$APP_VER.xapk" -d "$TEMP_DIR"; then
            break
        elif [[ $attempt -eq 3 ]]; then
            notify msg "Failed to unzip XAPK after 3 attempts!"
            rm -rf "$TEMP_DIR"
            return 1
        fi
        sleep $((attempt * 2))
    done

    # Stream-process manifest
    MANIFEST="$TEMP_DIR/manifest.json"
    [[ ! -f "$MANIFEST" ]] && {
        notify msg "manifest.json missing in XAPK!"
        rm -rf "$TEMP_DIR"
        return 1
    }

    # Single-pass JSON parsing
    eval "$(jq -r '.split_apks[] | "SPLIT_MAP[\(.id)]=\"\(.file)\""' "$MANIFEST")"
    
    BASE_APK="${SPLIT_MAP[base]}"
    [[ -z "$BASE_APK" ]] && {
        notify msg "Base APK not found in manifest!"
        rm -rf "$TEMP_DIR"
        return 1
    }

    # Architecture handling with fallback
    local ARCH_SPLIT="config.${ARCH//-/_}"
    if [[ ! -v SPLIT_MAP[$ARCH_SPLIT] ]]; then
        [[ "$ARCH" == "arm64-v8a" ]] && ARCH_SPLIT="config.armeabi_v7a"
        [[ ! -v SPLIT_MAP[$ARCH_SPLIT] ]] && {
            notify msg "No compatible architecture for $ARCH!"
            rm -rf "$TEMP_DIR"
            return 1
        }
    fi

    # Smart DPI selection
    local DPI_BUCKET=$(get_dpi_bucket)
    local DPI_SPLIT="config.$DPI_BUCKET"
    [[ ! -v SPLIT_MAP[$DPI_SPLIT] ]] && DPI_SPLIT=""

    # Language selection
    local LANG_OPTIONS=() LANG_SELECTED
    for lang_id in "${!SPLIT_MAP[@]}"; do
        [[ "$lang_id" =~ ^config\.[a-z]{2}$ ]] || continue
        code="${lang_id#config.}"
        lang_name=$(get_language_name "$code")
        [[ "$code" == "en" ]] && selected="on" || selected="off"
        LANG_OPTIONS+=("$lang_id" "$lang_name" "$selected")
    done

    notify info "Loading languages... [40%]"
    LANG_SELECTED=$(dialog --backtitle 'Enhancify' --title "Select Languages" \
        --ok-label "Continue" \
        --checklist "English Selected By Default:" \
        -1 -1 5 "${LANG_OPTIONS[@]}" 3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && {
        notify info "Language selection canceled"
        rm -rf "$TEMP_DIR"
        return 1
    }

    # Language summary
    if [[ -z "$LANG_SELECTED" ]]; then
        notify info "Using default base language\nMay cause text issues in some regions"
    else
        lang_names=()
        for lang_id in $LANG_SELECTED; do
            code=${lang_id#config.}
            lang_names+=("$(get_language_name "$code")")
        done
        
        local lang_count=${#lang_names[@]}
        if (( lang_count == 1 )); then
            msg="${lang_names[0]}"
        elif (( lang_count == 2 )); then
            msg="${lang_names[0]} and ${lang_names[1]}"
        elif (( lang_count == 3 )); then
            msg="${lang_names[0]}, ${lang_names[1]} and ${lang_names[2]}"
        else
            msg="${lang_names[0]}, ${lang_names[1]} and $((lang_count - 2)) others"
        fi
        notify info "Configuring Languages : $msg"

sleep 1

    fi

    # Prepare merge directory
    MERGE_DIR="$APP_DIR/merge"
    mkdir -p "$MERGE_DIR"
    notify info "Preparing files... [60%]"

    # Copy required splits
    cp "$TEMP_DIR/${SPLIT_MAP[base]}" "$MERGE_DIR/base.apk"
    [[ -n "$DPI_SPLIT" ]] && cp "$TEMP_DIR/${SPLIT_MAP[$DPI_SPLIT]}" "$MERGE_DIR/"
    cp "$TEMP_DIR/${SPLIT_MAP[$ARCH_SPLIT]}" "$MERGE_DIR/"
    for lang in $LANG_SELECTED; do
        cp "$TEMP_DIR/${SPLIT_MAP[$lang]}" "$MERGE_DIR/"
    done

    # Merge with retries
    for attempt in {1..2}; do
        notify info "Building APK... [$((60 + attempt*15))%]"
        if java -jar bin/APKEditor.jar m -i "$MERGE_DIR" -o "apps/$APP_NAME/$APP_VER.apk" &>/dev/null; then
            break
        elif [[ $attempt -eq 2 ]]; then
            notify msg "Merge failed after 2 attempts!\nCheck APKEditor"
            rm -rf "$TEMP_DIR" "$MERGE_DIR"
            return 1
        fi
        
    done

    # Cleanup
    notify info "Finalizing... [90%]"
    rm -rf "$TEMP_DIR" "$MERGE_DIR"
    rm "apps/$APP_NAME/$APP_VER.xapk" 2>/dev/null

    [[ "$ROOT_ACCESS" == false ]] && rm -rf "$APP_DIR"

    setEnv "APP_SIZE" "$(stat -c %s "apps/$APP_NAME/$APP_VER.apk")" update "apps/$APP_NAME/.data"
    notify info "Processing complete! [100%]"

sleep 2

}

# Improved DPI bucket selection with fallback
get_dpi_bucket() {
    local density=$(getprop ro.sf.lcd_density)
    declare -A buckets=(
        [ldpi]=120 [mdpi]=160 [hdpi]=240
        [xhdpi]=320 [xxhdpi]=480 [xxxhdpi]=640
    )
    
    local closest="nodpi" min_diff=10000
    for bucket in "${!buckets[@]}"; do
        diff=$(( density - buckets[$bucket] ))
        diff=${diff/-}  # Absolute value
        if (( diff < min_diff )); then
            min_diff=$diff
            closest=$bucket
        fi
    done
    echo "$closest"
}

# Cached language names for performance
get_language_name() {
    local code=$1
    declare -gA LANG_CACHE
    [[ -v LANG_CACHE[$code] ]] && { echo "${LANG_CACHE[$code]}"; return; }

    declare -A lang_map=(
        [en]="English"       [es]="Spanish"     [fr]="French"
        [de]="German"        [it]="Italian"     [pt]="Portuguese"
        [ru]="Russian"       [zh]="Chinese"     [ja]="Japanese"
        [ko]="Korean"        [ar]="Arabic"      [hi]="Hindi"
        [in]="Indonesian"    [ms]="Malay"       [th]="Thai"
        [vi]="Vietnamese"    [tr]="Turkish"
    )

    LANG_CACHE[$code]="${lang_map[$code]:-$code}"
    echo "${LANG_CACHE[$code]}"
}
