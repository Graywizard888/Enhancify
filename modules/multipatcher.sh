#!/usr/bin/bash

MULTI_SOURCES=()
MULTI_PATCHES_FILES=()

_get_patches_storage_key() {
    if [ "$ENABLE_MULTIPATCHER" = "on" ] && [ "${#MULTI_SOURCES[@]}" -gt 1 ]; then
        local IFS='&'
        echo "${MULTI_SOURCES[*]}"
    else
        echo "$SOURCE"
    fi
}

_get_source_cli_family() {
    local source="$1"
    [ "$source" = "ReVanced" ] && echo "revanced" && return
    local data_file="assets/$source/.data"
    if [ -f "$data_file" ]; then
        local ext
        ext=$(grep "^PATCHES_EXT=" "$data_file" | cut -d"'" -f2 | head -1)
        [ "$ext" = "rvp" ] && echo "inotia" || echo "morphe"
        return
    fi
    echo "morphe"
}

_fetchAdditionalSourceInfo() {
    local add_source="$1"

    local GITHUB_TOKEN
    GITHUB_TOKEN=$(read_github_token)
    local AUTH_HEADER=""
    [ -n "$GITHUB_TOKEN" ] && AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"

    local CURL_CMD=("${CURL[@]}" \
        --compressed --retry 3 --retry-delay 1 \
        -A "$USER_AGENT_GITHUB" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    [ -n "$AUTH_HEADER" ] && CURL_CMD+=(-H "$AUTH_HEADER")

    rm -rf "assets/$add_source"
    mkdir -p "assets/$add_source"

    local REPO
    REPO=$(get_all_sources | jq -r --arg s "$add_source" '.[] | select(.source == $s) | .repository // ""')
    [ -z "$REPO" ] && return 1

    local PATCHES_API_URL
    if [ "$USE_PRE_RELEASE" = "on" ]; then
        PATCHES_API_URL="https://api.github.com/repos/$REPO/releases"
    else
        PATCHES_API_URL="https://api.github.com/repos/$REPO/releases/latest"
    fi

    "${CURL_CMD[@]}" "$PATCHES_API_URL" > response_extra.tmp 2>/dev/null

    if ! jq -e 'if type == "array" then .[0] else . end | .tag_name' response_extra.tmp &>/dev/null; then
        rm -f response_extra.tmp
        return 1
    fi

    jq -r 'if type == "array" then .[0] else . end | .body // empty' \
        response_extra.tmp > "$HOME/Enhancify/changelog_${add_source}.tmp" 2>/dev/null

    local PATCHES_EXT
    PATCHES_EXT=$(get_patches_extension_from_api "response_extra.tmp")

    if ! jq -r --arg ext "$PATCHES_EXT" '
        if type == "array" then .[0] else . end |
        "PATCHES_VERSION='\''\(.tag_name)'\''",
        "PATCHES_EXT='\''" + $ext + "'\''",
        (
            .assets[] |
            select(
                (.name | endswith(".asc")  | not) and
                (.name | endswith(".json") | not) and
                (.name | endswith("." + $ext))
            ) |
            "PATCHES_URL='\''\(.browser_download_url)'\''",
            "PATCHES_SIZE='\''\(.size|tostring)'\''"
        )
    ' response_extra.tmp > "assets/$add_source/.data" 2>/dev/null; then
        rm -f response_extra.tmp
        return 1
    fi

    local JSON_URL_EXTRA
    JSON_URL_EXTRA=$(get_all_sources | jq -r --arg s "$add_source" '.[] | select(.source == $s) | .api.json // ""')
    [ -n "$JSON_URL_EXTRA" ] && setEnv JSON_URL "$JSON_URL_EXTRA" init "assets/$add_source/.data"

    rm -f response_extra.tmp
    return 0
}

_showOneChangelog() {
    local src="$1"
    local button_label="$2"
    local idx="$3"
    local total="$4"

    local changelog_file
    if [ "$src" = "${MULTI_SOURCES[0]}" ]; then
        changelog_file="$HOME/Enhancify/changelog.tmp"
    else
        changelog_file="$HOME/Enhancify/changelog_${src}.tmp"
    fi

    [ ! -f "$changelog_file" ] || [ ! -s "$changelog_file" ] && return 0

    local display_file="$HOME/Enhancify/changelog_display_${src}.tmp"

    {
        echo " SOURCE  : $src ($idx of $total)"
        local src_data="assets/$src/.data"
        if [ -f "$src_data" ]; then
            local sv se
            sv=$(grep "^PATCHES_VERSION=" "$src_data" | cut -d"'" -f2 | head -1)
            se=$(grep "^PATCHES_EXT=" "$src_data" | cut -d"'" -f2 | head -1)
            echo " Patches : ${sv}.${se}"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    } > "$display_file"

    local wrap_width
    wrap_width=$(getChangelogWrapWidth)

    formatChangelogBody "$changelog_file" "$wrap_width" >> "$display_file"

    "${DIALOG[@]}" \
        --title "| Changelog: $src ($idx/$total) |" \
        --exit-label "$button_label" \
        --scrollbar \
        --textbox "$display_file" -1 -1

    rm -f "$display_file" "$changelog_file"
}

showMultiChangelogs() {
    local total=${#MULTI_SOURCES[@]}
    local idx=0
    for src in "${MULTI_SOURCES[@]}"; do
        (( idx++ ))
        local button_label
        [ "$idx" -eq "$total" ] && button_label="Download" || button_label="Next"
        _showOneChangelog "$src" "$button_label" "$idx" "$total"
    done
    rm -f "$HOME/Enhancify/changelog.tmp"
}

buildMultiPatchesFilesList() {
    MULTI_PATCHES_FILES=()
    for src in "${MULTI_SOURCES[@]}"; do
        local src_data="assets/$src/.data"
        [ ! -f "$src_data" ] && continue
        local sv se
        sv=$(grep "^PATCHES_VERSION=" "$src_data" | cut -d"'" -f2 | head -1)
        se=$(grep "^PATCHES_EXT=" "$src_data" | cut -d"'" -f2 | head -1)
        [ -n "$sv" ] && [ -n "$se" ] && MULTI_PATCHES_FILES+=("assets/$src/Patches-${sv}.${se}")
    done
}

buildMultiPatchArguments() {
    PATCHES_ARGS=()
    ARGUMENTS=()

    local -a ENABLED_NAMES=()
    readarray -t ENABLED_NAMES < <(
        jq -nr --arg PKG_NAME "$PKG_NAME" --argjson ENABLED_PATCHES "$ENABLED_PATCHES" '
            $ENABLED_PATCHES[] | select(.pkgName == $PKG_NAME) | .patches[]
        '
    )

    local OPTIONS_JSON
    OPTIONS_JSON=$(
        jq -nc --arg PKG_NAME "$PKG_NAME" --argjson ENABLED_PATCHES "$ENABLED_PATCHES" '
            [$ENABLED_PATCHES[] | select(.pkgName == $PKG_NAME) | .options[]?]
        '
    )

    local -A CLAIMED=()
    local src src_data sv se pf src_json name opt_line
    for src in "${MULTI_SOURCES[@]}"; do
        src_data="assets/$src/.data"
        [ ! -f "$src_data" ] && continue
        sv=$(grep "^PATCHES_VERSION=" "$src_data" | cut -d"'" -f2 | head -1)
        se=$(grep "^PATCHES_EXT=" "$src_data" | cut -d"'" -f2 | head -1)
        pf="assets/$src/Patches-${sv}.${se}"
        [ -f "$pf" ] || continue
        PATCHES_ARGS+=("--patches=$pf")

        src_json="assets/$src/Patches-${sv}.json"
        [ -f "$src_json" ] || continue

        local -A SRC_NAMES=()
        while IFS= read -r name; do
            [ -n "$name" ] && SRC_NAMES["$name"]=1
        done < <(
            jq -r --arg PKG_NAME "$PKG_NAME" '
                .[] | select(.pkgName == $PKG_NAME or .pkgName == null) |
                (.patches.recommended[]?, .patches.optional[]?)
            ' "$src_json" 2> /dev/null
        )

        for name in "${ENABLED_NAMES[@]}"; do
            [ -n "${CLAIMED[$name]:-}" ] && continue
            [ -n "${SRC_NAMES[$name]:-}" ] || continue
            CLAIMED["$name"]=1
            PATCHES_ARGS+=("--enable" "$name")
            while IFS= read -r opt_line; do
                [ -n "$opt_line" ] && PATCHES_ARGS+=("$opt_line")
            done < <(
                jq -nr --arg NAME "$name" --argjson OPTIONS "$OPTIONS_JSON" '
                    $OPTIONS[] | select(.patchName == $NAME) |
                    "--options=" + .key + "=" + (.value | if . != null then (. | tostring) else empty end)
                '
            )
        done
        unset SRC_NAMES
    done
}

_collectMultiDownloads() {
    local -n _mu=$1 _md=$2 _mf=$3 _ms=$4 _ml=$5

    local cli_actual_size
    cli_actual_size=$(stat -c %s "$CLI_FILE" 2>/dev/null)
    local cli_ok=false
    if [ "$CLI_SIZE" = "0" ]; then
        [ -f "$CLI_FILE" ] && [ -s "$CLI_FILE" ] && cli_ok=true
    else
        [ "$CLI_SIZE" = "$cli_actual_size" ] && cli_ok=true
    fi

    if [ "$cli_ok" = false ]; then
        if get_cached_cli "$SOURCE" "$CLI_VERSION" "$CLI_FILE"; then
            notify info "CLI cache hit: CLI-$CLI_VERSION.jar"
        else
            _mu+=("$CLI_URL")
            _md+=("$(dirname "$CLI_FILE")")
            _mf+=("$(basename "$CLI_FILE")")
            _ms+=("$CLI_SIZE")
            _ml+=("CLI-$CLI_VERSION.jar")
        fi
    fi

    local primary_data="assets/$SOURCE/.data"
    if [ -f "$primary_data" ]; then
        local pv pe pu ps pf
        pv=$(grep "^PATCHES_VERSION=" "$primary_data" | cut -d"'" -f2 | head -1)
        pe=$(grep "^PATCHES_EXT=" "$primary_data" | cut -d"'" -f2 | head -1)
        pu=$(grep "^PATCHES_URL=" "$primary_data" | cut -d"'" -f2 | head -1)
        ps=$(grep "^PATCHES_SIZE=" "$primary_data" | cut -d"'" -f2 | head -1)
        pf="assets/$SOURCE/Patches-${pv}.${pe}"
        local pa
        pa=$(stat -c %s "$pf" 2>/dev/null)
        local pneed=false
        if [ "$ps" = "0" ]; then
            [ ! -f "$pf" ] || [ ! -s "$pf" ] && pneed=true
        else
            [ "$ps" != "$pa" ] && pneed=true
        fi
        if $pneed && [ -n "$pu" ]; then
            _mu+=("$pu"); _md+=("assets/$SOURCE"); _mf+=("Patches-${pv}.${pe}")
            _ms+=("$ps"); _ml+=("[$SOURCE] Patches-${pv}.${pe}")
        fi
    fi

    for src in "${MULTI_SOURCES[@]:1}"; do
        local src_data="assets/$src/.data"
        [ ! -f "$src_data" ] && continue
        local sv se su ss sf sa
        sv=$(grep "^PATCHES_VERSION=" "$src_data" | cut -d"'" -f2 | head -1)
        se=$(grep "^PATCHES_EXT=" "$src_data" | cut -d"'" -f2 | head -1)
        su=$(grep "^PATCHES_URL=" "$src_data" | cut -d"'" -f2 | head -1)
        ss=$(grep "^PATCHES_SIZE=" "$src_data" | cut -d"'" -f2 | head -1)
        sf="assets/$src/Patches-${sv}.${se}"
        sa=$(stat -c %s "$sf" 2>/dev/null)

        local needs_dl=false
        if [ "$ss" = "0" ]; then
            [ ! -f "$sf" ] || [ ! -s "$sf" ] && needs_dl=true
        else
            [ "$ss" != "$sa" ] && needs_dl=true
        fi
        if $needs_dl && [ -n "$su" ]; then
            _mu+=("$su"); _md+=("assets/$src"); _mf+=("Patches-${sv}.${se}")
            _ms+=("$ss"); _ml+=("[$src] Patches-${sv}.${se}")
        fi
    done
}

fetchMultiSourceAssets() {
    [ ${#MULTI_SOURCES[@]} -le 1 ] && return 0

    for src in "${MULTI_SOURCES[@]:1}"; do
        notify info "Fetching info for additional source: $src..."
        if ! _fetchAdditionalSourceInfo "$src"; then
            notify msg "Failed to fetch info for $src. Removing from selection."
            MULTI_SOURCES=("${MULTI_SOURCES[@]/$src}")
            local cleaned=()
            for s in "${MULTI_SOURCES[@]}"; do [ -n "$s" ] && cleaned+=("$s"); done
            MULTI_SOURCES=("${cleaned[@]}")
            continue
        fi

        local primary_family src_family
        primary_family=$(_get_source_cli_family "$SOURCE")
        src_family=$(_get_source_cli_family "$src")
        if [ "$src_family" != "$primary_family" ]; then
            notify msg "$src uses a patch format incompatible with $SOURCE.\nRemoving from selection."
            rm -f "assets/$src/.data" "$HOME/Enhancify/changelog_${src}.tmp"
            MULTI_SOURCES=("${MULTI_SOURCES[@]/$src}")
            local cleaned=()
            for s in "${MULTI_SOURCES[@]}"; do [ -n "$s" ] && cleaned+=("$s"); done
            MULTI_SOURCES=("${cleaned[@]}")
        fi
    done

    showMultiChangelogs

    local mu=() md=() mf=() ms=() ml=()
    _collectMultiDownloads mu md mf ms ml

    if [ ${#mu[@]} -gt 0 ]; then
        downloadBatchAria2c mu md mf ms ml || return 1
    fi

    if [ "$CACHE_CLI" = "on" ]; then
        local cli_actual_size
        cli_actual_size=$(stat -c %s "$CLI_FILE" 2>/dev/null)
        local cli_size_ok=false
        if [ "$CLI_SIZE" = "0" ]; then
            [ -f "$CLI_FILE" ] && [ -s "$CLI_FILE" ] && cli_size_ok=true
        else
            [ "$CLI_SIZE" = "$cli_actual_size" ] && cli_size_ok=true
        fi
        [ "$cli_size_ok" = true ] && save_cli_to_cache "$SOURCE" "$CLI_VERSION" "$CLI_FILE"
    fi

    buildMultiPatchesFilesList
    return 0
}

parseMultiSourcePatchesJson() {
    local save_SOURCE="$SOURCE"
    local save_PATCHES_FILE="$PATCHES_FILE"
    local save_PATCHES_VERSION="$PATCHES_VERSION"
    local save_JSON_URL="$JSON_URL"

    for src in "${MULTI_SOURCES[@]}"; do
        local src_data="assets/$src/.data"
        [ ! -f "$src_data" ] && continue
        local sv se jurl
        sv=$(grep "^PATCHES_VERSION=" "$src_data" | cut -d"'" -f2 | head -1)
        se=$(grep "^PATCHES_EXT=" "$src_data" | cut -d"'" -f2 | head -1)
        jurl=$(grep "^JSON_URL=" "$src_data" | cut -d"'" -f2 | head -1 2>/dev/null || echo "")

        local src_json="assets/$src/Patches-${sv}.json"
        [ -f "$src_json" ] && continue

        SOURCE="$src"
        PATCHES_VERSION="$sv"
        PATCHES_FILE="assets/$src/Patches-${sv}.${se}"
        JSON_URL="$jurl"

        if [ -n "$JSON_URL" ]; then
            parseJsonFromAPI
        else
            parseJsonFromCLI | "${DIALOG[@]}" \
                --gauge "Parsing patches for $src...\nThis might take some time." -1 -1 0
            tput civis
        fi
    done

    SOURCE="$save_SOURCE"
    PATCHES_FILE="$save_PATCHES_FILE"
    PATCHES_VERSION="$save_PATCHES_VERSION"
    JSON_URL="$save_JSON_URL"

    local merged="[]"
    for src in "${MULTI_SOURCES[@]}"; do
        local src_data="assets/$src/.data"
        [ ! -f "$src_data" ] && continue
        local sv se
        sv=$(grep "^PATCHES_VERSION=" "$src_data" | cut -d"'" -f2 | head -1)
        se=$(grep "^PATCHES_EXT=" "$src_data" | cut -d"'" -f2 | head -1)
        local src_json="assets/$src/Patches-${sv}.json"
        [ ! -f "$src_json" ] && continue

        merged=$(jq -n \
            --argjson base "$merged" \
            --argjson add "$(jq -rc '.' "$src_json")" \
            '
            ($base + $add) |
            group_by(.pkgName // "universal") |
            map(
                reduce .[] as $item ({};
                    .pkgName = ($item.pkgName // null) |
                    .versions = (((.versions // []) + ($item.versions // [])) | unique) |
                    .patches = {
                        recommended: (
                            ((.patches.recommended // []) + ($item.patches.recommended // [])) | unique
                        ),
                        optional: (
                            ((.patches.optional // []) + ($item.patches.optional // [])) | unique
                        )
                    } |
                    .options      = ((.options      // []) + ($item.options      // [])) |
                    .descriptions = ((.descriptions // {}) * ($item.descriptions // {}))
                )
            )
            ')
    done

    AVAILABLE_PATCHES="$merged"

    [ -n "$ENABLED_PATCHES" ] || \
        ENABLED_PATCHES=$(jq -erc '.' "$STORAGE/$(_get_patches_storage_key)-patches.json" 2>/dev/null || echo '[]')

    while [ -z "$APPS_LIST" ]; do
        if [ -e "assets/$SOURCE/Apps-$PATCHES_VERSION.json" ]; then
            readarray -t APPS_LIST < <(
                jq -rc '
                    reduce .[] as $APP_INFO (
                        [];
                        if any(.[]; .[1] == $APP_INFO.appName) then
                            . += [[$APP_INFO, "\($APP_INFO.appName) [\($APP_INFO.pkgName)]"]]
                        else
                            . += [[$APP_INFO, $APP_INFO.appName]]
                        end
                    ) |
                    .[][]
                ' "assets/$SOURCE/Apps-$PATCHES_VERSION.json"
            )
        fi
        if [ ${#APPS_LIST[@]} -eq 0 ]; then
            unset APPS_LIST
            rm assets/"$SOURCE"/Apps-*.json &>/dev/null
            fetchAppsInfo || return 1
        fi
    done
}
