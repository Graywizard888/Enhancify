#!/usr/bin/bash

CONFIG_FILE="$HOME/Enhancify/apkmirror_config.json"

get_max_page_limit() {
    local limit
    if [[ -f "$CONFIG_FILE" ]]; then
        limit=$(jq -r '.max_page_limit // 5' "$CONFIG_FILE" 2>/dev/null)
        if [[ "$limit" =~ ^[0-9]+$ ]] && [[ -n "$limit" ]]; then
            echo "$limit"
        else
            echo "5"
        fi
    else
        echo "5"
    fi
}

processVersionsJson() {
    local json_data="$1"
    
    readarray -t VERSIONS_LIST < <(
        jq -rc \
            --arg PKG_NAME "$PKG_NAME" \
            --arg INSTALLED_VERSION "$INSTALLED_VERSION" \
            --arg ALLOW_APP_VERSION_DOWNGRADE "$ALLOW_APP_VERSION_DOWNGRADE" \
            --argjson AVAILABLE_PATCHES "$AVAILABLE_PATCHES" '
            . as $ALL_VERSIONS |
            (
                $AVAILABLE_PATCHES[] |
                select(.pkgName == $PKG_NAME) |
                .versions
            ) as $SUPPORTED_VERSIONS |
            $ALL_VERSIONS |
            map(
                .version as $VERSION |
                if ($SUPPORTED_VERSIONS != null and ($SUPPORTED_VERSIONS | index($VERSION)) != null) then
                    .tag = "[RECOMMENDED]"
                elif .version == $INSTALLED_VERSION then
                    .tag = "[INSTALLED]"
                else
                    .
                end
            ) |
            (
                if any(.[]; .tag == "[RECOMMENDED]") then
                    (first(.[] | select(.tag == "[RECOMMENDED]"))), "Auto Select|[RECOMMENDED]"
                elif $INSTALLED_VERSION != "" then
                    .[-1], "Auto Select|[INSTALLED]"
                else
                    empty
                end
            ),
            (
                .[] |
                ., "\(.version)|\(.tag)"
            )
        ' <<< "$json_data"
    )
}

loadVersionsFromCache() {
    local cached_json
    cached_json=$(cache_metadata_manager "$APKMIRROR_APP_NAME" "read")
    
    if [[ -z "$cached_json" ]] || [[ "$cached_json" == "[]" ]]; then
        return 1
    fi
    
    processVersionsJson "$cached_json"
    return 0
}

scrapeVersionsList() {
    local PAGE_CONTENTS PAGE_JSON MERGED_JSON
    local IDX MAX_PAGE_COUNT
    local -a TMP_FILES

    MAX_PAGE_COUNT=$(get_max_page_limit)

    for ((IDX = 1; IDX <= MAX_PAGE_COUNT; IDX++)); do
        TMP_FILES[IDX]=$(mktemp)
        "${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com/uploads/page/$IDX/?appcategory=$APKMIRROR_APP_NAME" > "${TMP_FILES[$IDX]}" 2>/dev/null &
    done
    wait

    for ((IDX = 1; IDX <= MAX_PAGE_COUNT; IDX++)); do
        PAGE_CONTENTS[IDX]=$(cat "${TMP_FILES[$IDX]}")
        rm -f "${TMP_FILES[$IDX]}"
    done

    for ((IDX = 1; IDX <= MAX_PAGE_COUNT; IDX++)); do
        PAGE_JSON[IDX]=$(
            pup -c 'div.widget_appmanager_recentpostswidget div.listWidget div:not([class]) json{}' <<< "${PAGE_CONTENTS[$IDX]}" |
                jq -rc '
                .[].children as $CHILDREN |
                {
                    version: $CHILDREN[1].children[0].children[1].text,
                    info: $CHILDREN[0].children[0].children[1].children[0].children[0].children[0]
                } |
                    select(.version != null and .info != null) |
                {
                    version: .version,
                    tag: (
                        (.info.text // "") | ascii_downcase |
                        if test("beta") then
                            "[BETA]"
                        elif test("alpha") then
                            "[ALPHA]"
                        else
                            "[STABLE]"
                        end
                    ),
                    url: .info.href
                }
            '
        )
    done

    MERGED_JSON=$(jq -s '.' <<< "$(printf '%s\n' "${PAGE_JSON[@]}")")

    if [[ "$MERGED_JSON" == "[]" ]] || [[ -z "$MERGED_JSON" ]]; then
        notify msg "Unable to fetch versions !!\nThere is some problem with your internet connection. Disable VPN or Change your network."
        TASK="CHOOSE_APP"
        return 1
    fi

    cache_metadata_manager "$APKMIRROR_APP_NAME" "write" "$MERGED_JSON" "$MAX_PAGE_COUNT"

    processVersionsJson "$MERGED_JSON"
}

chooseVersion() {
    unset APP_VER APP_DL_URL
    local SELECTED_VERSION CACHE_TIMESTAMP
    local RECOMMENDED_COUNT
    local -a DIALOG_OPTIONS
    local MAX_PAGE_COUNT
    
    local APKMIRROR_STATUS="unreachable"
    if [[ "${APKMIRROR_REACHABLE:-false}" == "true" ]]; then
        APKMIRROR_STATUS="reachable"
    fi
    
    getInstalledVersion
    
    MAX_PAGE_COUNT=$(get_max_page_limit)
    
    if [[ "${#VERSIONS_LIST[@]}" -eq 0 ]]; then
        if cache_metadata_manager "$APKMIRROR_APP_NAME" "exists" "" "$MAX_PAGE_COUNT"; then
            CACHE_TIMESTAMP=$(cache_metadata_manager "$APKMIRROR_APP_NAME" "timestamp")
            notify info "Loading cached versions for $APP_NAME...\n(Cached: $CACHE_TIMESTAMP)"
            sleep 1
            if ! loadVersionsFromCache; then
                if [[ "$APKMIRROR_STATUS" == "unreachable" ]]; then
                    notify msg "APKMirror is unreachable and cache is invalid!\n\nStatus: ${ONLINE_STATUS:-Offline}\n\nPlease check your connection or try again later."
                    TASK="CHOOSE_APP"
                    return 1
                fi
                notify info "Cache invalid. Scraping versions for $APP_NAME..."
                sleep 1
                scrapeVersionsList || return 1
            fi
        else
            if [[ "$APKMIRROR_STATUS" == "unreachable" ]]; then
                notify msg "APKMirror is unreachable and no cached data available!\n\nStatus: ${ONLINE_STATUS:-Offline}\n\nPlease connect to the internet to fetch versions."
                TASK="CHOOSE_APP"
                return 1
            fi
            notify info "Please Wait !!\nScraping versions list for $APP_NAME from apkmirror.com..."
            sleep 1
            scrapeVersionsList || return 1
        fi
    fi
    
    CACHE_TIMESTAMP=$(cache_metadata_manager "$APKMIRROR_APP_NAME" "timestamp")
    RECOMMENDED_COUNT=$(getRecommendedVersionsCount)
    
    DIALOG_OPTIONS=()
    
    if [[ -n "$RECOMMENDED_COUNT" ]] && [[ "$RECOMMENDED_COUNT" =~ ^[0-9]+$ ]] && [[ "$RECOMMENDED_COUNT" -gt 0 ]]; then
        DIALOG_OPTIONS+=(
            "SHOW_RECOMMENDED" "Detected Recommended|($RECOMMENDED_COUNT versions)"
        )
    fi
    
    if [[ "$APKMIRROR_STATUS" == "reachable" ]]; then
        DIALOG_OPTIONS+=(
            "REFRESH_VERSIONS" "Refresh List|[Cached: ${CACHE_TIMESTAMP}]"
        )
    else
        DIALOG_OPTIONS+=(
            "REFRESH_VERSIONS" "Refresh List (${ONLINE_STATUS:-Offline})|[Cached: ${CACHE_TIMESTAMP}]"
        )
    fi
    
    DIALOG_OPTIONS+=(
        "${VERSIONS_LIST[@]}"
    )
    
    if ! SELECTED_VERSION=$(
        "${DIALOG[@]}" \
            --title '| Version Selection Menu |' \
            --no-tags \
            --column-separator "|" \
            --default-item "$SELECTED_VERSION" \
            --ok-label 'Select' \
            --cancel-label 'Back' \
            --menu "$NAVIGATION_HINT" -1 -1 0 \
            "${DIALOG_OPTIONS[@]}" \
            2>&1 > /dev/tty
    ); then
        TASK="CHOOSE_APP"
        return 1
    fi
    
    case "$SELECTED_VERSION" in
        "SHOW_RECOMMENDED")
            if showRecommendedVersions; then
                return 0
            else
                chooseVersion
                return $?
            fi
            ;;
        "REFRESH_VERSIONS")
            if [[ "$APKMIRROR_STATUS" == "unreachable" ]]; then
                notify msg "Cannot refresh versions list!\n\nStatus: ${ONLINE_STATUS:-Offline}\nAPKMirror is not reachable.\n\nYou are viewing cached data."
                chooseVersion
                return $?
            fi
            cache_metadata_manager "$APKMIRROR_APP_NAME" "clear"
            unset VERSIONS_LIST
            notify info "Refreshing versions list for $APP_NAME..."
            sleep 1
            scrapeVersionsList || return 1
            chooseVersion
            return $?
            ;;
        *)
            APP_VER=$(jq -nrc --argjson SELECTED_VERSION "$SELECTED_VERSION" '$SELECTED_VERSION.version | sub(" "; ""; "g")')
            APP_DL_URL=$(jq -nrc --argjson SELECTED_VERSION "$SELECTED_VERSION" '"https://www.apkmirror.com" + $SELECTED_VERSION.url')
            ;;
    esac
}
