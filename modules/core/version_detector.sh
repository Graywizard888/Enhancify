#!/usr/bin/bash

getRecommendedVersionsCount() {
    local count
    count=$(jq -r --arg PKG_NAME "$PKG_NAME" \
           --argjson AVAILABLE_PATCHES "$AVAILABLE_PATCHES" '
        [$AVAILABLE_PATCHES[] | select(.pkgName == $PKG_NAME) | .versions // []] |
        if length > 0 then .[0] | length else 0 end
    ' <<< "null")
    
    echo "${count:-0}"
}

fetchFirstVersionUrl() {
    local PAGE_CONTENT FIRST_URL
    
    PAGE_CONTENT=$("${CURL[@]}" -A "$USER_AGENT" "https://www.apkmirror.com/uploads/page/1/?appcategory=${APKMIRROR_APP_NAME}" 2>/dev/null)
    
    FIRST_URL=$(
        pup -c 'div.widget_appmanager_recentpostswidget div.listWidget div:not([class]) json{}' <<< "$PAGE_CONTENT" |
            jq -r '
                [.[].children as $CHILDREN | {
                    version: $CHILDREN[1].children[0].children[1].text,
                    url: $CHILDREN[0].children[0].children[1].children[0].children[0].children[0].href
                } | select(.version != null and .url != null)] |
                first | .url // empty
            ' 2>/dev/null
    )
    
    echo "$FIRST_URL"
}

validateUrl() {
    local URL="$1"
    local HTTP_CODE
    
    HTTP_CODE=$("${CURL[@]}" -A "$USER_AGENT" -s -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null)
    
    [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]
}

getVersionUrl() {
    local VERSION="$1"
    local CACHE_FILE BASE_URL FIRST_URL SELECTED_VERSION_FORMATTED FINAL_URL
    local safe_name="${APKMIRROR_APP_NAME//[^a-zA-Z0-9_-]/_}"
    
    CACHE_FILE="${CACHE_DIR}/${safe_name}_metadata.json"
    SELECTED_VERSION_FORMATTED="${VERSION//./-}"
    
    if [[ -f "$CACHE_FILE" ]]; then
        BASE_URL=$(jq -r '
            .versions[0].url // empty
        ' "$CACHE_FILE" 2>/dev/null)
        
        if [[ -n "$BASE_URL" && "$BASE_URL" != "null" ]]; then
            FINAL_URL=$(echo "https://www.apkmirror.com${BASE_URL}" | 
                sed -E "s/[0-9]+-[0-9]+-[0-9]+(-[0-9]+)?-release/${SELECTED_VERSION_FORMATTED}-release/")
            
            if validateUrl "$FINAL_URL"; then
                echo "$FINAL_URL"
                return 0
            fi
        fi
    fi
    
    FIRST_URL=$(fetchFirstVersionUrl)
    
    if [[ -n "$FIRST_URL" ]]; then
        FINAL_URL=$(echo "https://www.apkmirror.com${FIRST_URL}" | 
            sed -E "s/[0-9]+-[0-9]+-[0-9]+(-[0-9]+)?-release/${SELECTED_VERSION_FORMATTED}-release/")
        
        if validateUrl "$FINAL_URL"; then
            echo "$FINAL_URL"
            return 0
        fi
    fi
    
    echo "https://www.apkmirror.com${APKMIRROR_APP_URL}${APKMIRROR_APP_NAME}-${SELECTED_VERSION_FORMATTED}-release/"
}

showRecommendedVersions() {
    local SELECTED_VERSION EXIT_CODE
    local -a RECOMMENDED_LIST

    readarray -t RECOMMENDED_LIST < <(
        jq -r --arg PKG_NAME "$PKG_NAME" \
              --arg INSTALLED_VERSION "$INSTALLED_VERSION" \
              --argjson AVAILABLE_PATCHES "$AVAILABLE_PATCHES" '

            [$AVAILABLE_PATCHES[] | select(.pkgName == $PKG_NAME) | .versions // []] |
            if length > 0 then .[0] else [] end |
            
            if length == 0 then
                empty
            else
                reverse | .[] |
                
                . as $ver |
                if $ver == $INSTALLED_VERSION then
                    $ver, "[INSTALLED]"
                else
                    $ver, "[AVAILABLE]"
                end
            end
        ' <<< "null"
    )

    if [[ ${#RECOMMENDED_LIST[@]} -eq 0 ]]; then
        notify msg "Unable to get recommended versions for ${APP_NAME}"
        return 1
    fi

    SELECTED_VERSION=$(
        "${DIALOG[@]}" --title '| Recommended Versions |' \
            --ok-label 'Select' --cancel-label 'Back' \
            --menu "$NAVIGATION_HINT" -1 -1 0 "${RECOMMENDED_LIST[@]}" 2>&1 >/dev/tty
    )
    EXIT_CODE=$?

    case "$EXIT_CODE" in
        0)
            APP_VER="${SELECTED_VERSION// /}"
            
            notify info "Fetching download URL for ${APP_NAME} ${APP_VER}..."
            
            APP_DL_URL=$(getVersionUrl "$APP_VER")
            
            return 0
            ;;
        1)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}
