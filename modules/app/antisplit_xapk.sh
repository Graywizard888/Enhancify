antisplit_xapk() {
    local APP_DIR LOCALE TEMP_DIR MANIFEST BASE_APK AVAILABLE_ARCHS ARCH_SPLIT
    local DPI_SPLIT LANG_OPTIONS=() LANG_SELECTED LANG_SPLITS MERGE_DIR
    local lang_names=() lang_name code msg

    notify info "Please Wait !!\nProcessing XAPK ..."

    APP_DIR="apps/$APP_NAME/$APP_VER"
    TEMP_DIR="$APP_DIR/temp"
    mkdir -p "$TEMP_DIR"

    
    unzip -qqo "apps/$APP_NAME/$APP_VER.xapk" -d "$TEMP_DIR" || {
        notify msg "Failed to unzip XAPK file!"
        rm -rf "$TEMP_DIR"
        return 1
    }

    MANIFEST="$TEMP_DIR/manifest.json"
    [[ ! -f "$MANIFEST" ]] && {
        notify msg "manifest.json missing in XAPK!"
        rm -rf "$TEMP_DIR"
        return 1
    }

    
    BASE_APK=$(jq -r '.split_apks[] | select(.id=="base") | .file' "$MANIFEST")
    [[ -z "$BASE_APK" ]] && {
        notify msg "Base APK not found in manifest!"
        rm -rf "$TEMP_DIR"
        return 1
    }

  
    AVAILABLE_ARCHS=$(jq -r '.split_apks[].id' "$MANIFEST" | grep -E 'config\.(arm64_v8a|armeabi_v7a|x86|x86_64)')
    ARCH_SPLIT="config.${ARCH//-/_}"

    if ! grep -q "$ARCH_SPLIT" <<< "$AVAILABLE_ARCHS"; then
        notify msg "No compatible architecture split found for $ARCH!"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    
    DPI_SPLIT="config.$(get_dpi_bucket).apk"
    [[ ! -f "$TEMP_DIR/$DPI_SPLIT" ]] && DPI_SPLIT=""

   
    while read -r lang_id; do
        lang_code="${lang_id#config.}"
        lang_name=$(get_language_name "$lang_code")
        [[ "$lang_code" == "en" ]] && selected="on" || selected="off"
        LANG_OPTIONS+=("$lang_id" "$lang_name" "$selected")
    done < <(jq -r '.split_apks[].id' "$MANIFEST" | grep -E 'config\.[a-z]{2}$')

    
    LANG_SELECTED=$(dialog --backtitle 'Enhancify' --title "Select Languages" \
        --ok-label "Continue" \
        --no-cancel \
        --checklist "Choose languages to include (English selected by default):" \
        -1 -1 0 "${LANG_OPTIONS[@]}" 3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && {
        notify info "Language selection canceled"
        rm -rf "$TEMP_DIR"
        return 1
    }

    
    if [[ -z "$LANG_SELECTED" ]]; then
        notify info "Configuring default base APK language\nThis may cause text display issues in some regions"
    else
        
        for lang_id in $LANG_SELECTED; do
            code=${lang_id#config.}
            lang_names+=("$(get_language_name "$code")")
        done

        
        if [[ ${#lang_names[@]} -eq 1 ]]; then
            msg="Configuring ${lang_names[0]} language"
        elif [[ ${#lang_names[@]} -eq 2 ]]; then
            msg="Configuring ${lang_names[0]} and ${lang_names[1]} languages"
        elif [[ ${#lang_names[@]} -eq 3 ]]; then
            msg="Configuring ${lang_names[0]}, ${lang_names[1]} and ${lang_names[2]} languages"
        else
            msg="Configuring ${lang_names[0]}, ${lang_names[1]} and $(( ${#lang_names[@]} - 2 )) more languages"
        fi

        notify info "$msg"
    fi

    
    MERGE_DIR="$APP_DIR/merge"
    mkdir -p "$MERGE_DIR"

    
    cp "$TEMP_DIR/$BASE_APK" "$MERGE_DIR/base.apk"
    [[ -n "$DPI_SPLIT" ]] && cp "$TEMP_DIR/$DPI_SPLIT" "$MERGE_DIR/"
    cp "$TEMP_DIR/${ARCH_SPLIT}.apk" "$MERGE_DIR/"
    for lang in $LANG_SELECTED; do
        cp "$TEMP_DIR/${lang}.apk" "$MERGE_DIR/"
    done

    
    java -jar bin/APKEditor.jar m -i "$MERGE_DIR" -o "apps/$APP_NAME/$APP_VER.apk" &> /dev/null || {
        notify msg "APK merge failed!\nCheck APKEditor installation"
        rm -rf "$TEMP_DIR" "$MERGE_DIR"
        return 1
    }

    
    rm -rf "$TEMP_DIR" "$MERGE_DIR"
    rm "apps/$APP_NAME/$APP_VER.xapk" 2>/dev/null

    if [[ "$ROOT_ACCESS" == false ]]; then
        rm -rf "$APP_DIR"
    fi

    setEnv "APP_SIZE" "$(stat -c %s "apps/$APP_NAME/$APP_VER.apk")" update "apps/$APP_NAME/.data"
}


get_dpi_bucket() {
    local density=$(getprop ro.sf.lcd_density)
    case $density in
        *-*dpi) echo "${density//-*/}" ;;
        *)
            if (( density <= 120 )); then echo "ldpi"
            elif (( density <= 160 )); then echo "mdpi"
            elif (( density <= 240 )); then echo "hdpi"
            elif (( density <= 320 )); then echo "xhdpi"
            elif (( density <= 480 )); then echo "xxhdpi"
            else echo "xxxhdpi"
            fi
            ;;
    esac
}


get_language_name() {
    declare -A lang_map=(
        ["en"]="English"
        ["es"]="Spanish"
        ["fr"]="French"
        ["de"]="German"
        ["it"]="Italian"
        ["pt"]="Portuguese"
        ["ru"]="Russian"
        ["zh"]="Chinese"
        ["ja"]="Japanese"
        ["ko"]="Korean"
        ["ar"]="Arabic"
        ["hi"]="Hindi"
        ["in"]="Indonesian"
        ["ms"]="Malay"
        ["th"]="Thai"
        ["vi"]="Vietnamese"
        ["tr"]="Turkish"
        
    )

    local code=$1
    [[ -n "${lang_map[$code]}" ]] && echo "${lang_map[$code]} ($code)" || echo "$code"
}
