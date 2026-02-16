#!/usr/bin/bash

read_github_token() {
    local token_file="$HOME/Enhancify/github_token.json"
    
    if [ -f "$token_file" ]; then
        local token
        token=$(jq -r '.token' "$token_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi
    return 1
}

log_github_api_request() {
    local endpoint="$1"
    local response_headers="$2"
    
    local limit remaining reset
    limit=$(grep -i 'x-ratelimit-limit:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    remaining=$(grep -i 'x-ratelimit-remaining:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    reset=$(grep -i 'x-ratelimit-reset:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    
    [ -z "$limit" ] && limit="0"
    [ -z "$remaining" ] && remaining="0"
    [ -z "$reset" ] && reset="0"

    local log_file="$HOME/Enhancify/github_api_log.json"
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local log_entry=$(jq -n \
        --arg ts "$timestamp" \
        --arg ep "$endpoint" \
        --arg lim "$limit" \
        --arg rem "$remaining" \
        --arg res "$reset" \
        '{
            timestamp: $ts,
            endpoint: $ep,
            limit: $lim | tonumber,
            remaining: $rem | tonumber,
            reset: $res | tonumber
        }')
    
    if [ -f "$log_file" ]; then
        jq --argjson new "$log_entry" '. += [$new]' "$log_file" > tmp_log && mv tmp_log "$log_file"
    else
        echo "[$log_entry]" > "$log_file"
    fi
}

downloadFile() {
    local url="$1"
    local output_file="$2"
    local expected_size="$3"
    local gauge_text="$4"

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        local progress_file
        progress_file=$(mktemp)

        (
            local dir=$(dirname "$output_file")
            local file=$(basename "$output_file")
            cd "$dir" || exit 1

            aria2c --console-log-level=warn --summary-interval=1 --download-result=hide \
                   --no-conf \
                   --out="$file" \
                   --split=4 --min-split-size=5M --max-connection-per-server=4 \
                   --file-allocation=none \
                   "$url" 2>&1 | \
                while read -r line; do
                    if [[ "$line" =~ ([0-9]{1,3})% ]]; then
                        echo "${BASH_REMATCH[1]}" > "$progress_file"
                    fi
                done
        ) &
        local download_pid=$!

        while kill -0 $download_pid 2>/dev/null; do
            local progress
            progress=$(cat "$progress_file" 2>/dev/null || echo 0)
            echo "$progress"
            sleep 1
        done | "${DIALOG[@]}" --gauge "$gauge_text\nStatus: Parts:4 | mirrors connected 4" -1 -1 0

        wait $download_pid
        rm -f "$progress_file"
    else
        (
            "${WGET[@]}" "$url" -O "$output_file" |& \
            stdbuf -o0 cut -b 63-65 | stdbuf -o0 grep '[0-9]' | \
            while read -r line; do
                echo "$line"
            done
        ) | "${DIALOG[@]}" --gauge "$gauge_text" -1 -1 0
    fi

    [ "$expected_size" = "$(stat -c %s "$output_file" 2>/dev/null)" ]
}

get_patches_extension_from_api() {
    local api_response_file="$1"
    
    local response_data
    response_data=$(jq 'if type == "array" then .[0] else . end' "$api_response_file" 2>/dev/null)
    
    if jq -e '.assets[]? | select(.name | endswith(".mpp")) | select(.name | endswith(".asc") | not)' <<< "$response_data" &>/dev/null; then
        echo "mpp"
        return 0
    fi
    
    if jq -e '.assets[]? | select(.name | endswith(".rvp")) | select(.name | endswith(".asc") | not)' <<< "$response_data" &>/dev/null; then
        echo "rvp"
        return 0
    fi
    
    echo "mpp"
}

get_patches_extension() {
    local source="$1"
    
    if [ -d "assets/$source" ]; then
        if ls assets/"$source"/Patches-*.mpp 2>/dev/null | grep -q .; then
            echo "mpp"
            return 0
        fi
        if ls assets/"$source"/Patches-*.rvp 2>/dev/null | grep -q .; then
            echo "rvp"
            return 0
        fi
    fi
    
    case "$source" in
        MorpheApp|Wchill-patcheddit|RVX-Morphed|Anddea-Morphed|Anddea|PikoTwitter)
            echo "mpp"
            ;;
        *)
            echo "rvp"
            ;;
    esac
}

update_source_json_branch() {
    local source_name="$1"
    local main_branch="$2"
    local dev_branch="$3"
    
    if [ "$USE_PRE_RELEASE" == "on" ]; then
        jq --arg source "$source_name" --arg main "$main_branch" --arg dev "$dev_branch" '
            (.[] | select(.source == $source) | .api.json) |= sub($main; $dev)
        ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
    else
        jq --arg source "$source_name" --arg main "$main_branch" --arg dev "$dev_branch" '
            (.[] | select(.source == $source) | .api.json) |= sub($dev; $main)
        ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
    fi
}

update_sources_json() {
    local sources_config=(
        "Anddea:main:dev"
        "ReVanced-Extended:revanced-extended:dev"
        "ReVancedExperiments:main:dev"
        "PikoTwitter:main:dev"
        "MorpheApp:main:dev"
        "Wchill-patcheddit:main:dev"
        "RVX-Morphed:main:dev"
        "Anddea-Morphed:main:dev"
    )
    
    for config in "${sources_config[@]}"; do
        IFS=':' read -r source main_branch dev_branch <<< "$config"
        update_source_json_branch "$source" "$main_branch" "$dev_branch"
    done
}

fetchAssetsInfo() {
    rm -f "$HOME/Enhancify/github_api_log.json"
    unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL PATCHES_EXT

    for var in $(compgen -v | grep "^ASSET_"); do
        unset "$var"
    done
    
    local SOURCE_INFO VERSION PATCHES_API_URL
    local GITHUB_TOKEN
    GITHUB_TOKEN=$(read_github_token)
    local AUTH_HEADER=""
    local AUTH_TEXT=""

    if [ -n "$GITHUB_TOKEN" ]; then
        AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
        AUTH_TEXT="[Authorised]"
    fi

    local CURL_CMD=("${CURL[@]}" \
        --compressed \
        --retry 3 \
        --retry-delay 1 \
        -A "$USER_AGENT_GITHUB" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28")

    if [ -n "$AUTH_HEADER" ]; then
        CURL_CMD+=(-H "$AUTH_HEADER")
    fi

    CURL_CMD+=(-D headers.tmp)

    internet || return 1

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        notify info "Initiating Network Acceleration ...\nFetching Assets Info... $AUTH_TEXT"
    else
        notify info "Fetching Assets Info.. $AUTH_TEXT"
    fi

    "${CURL_CMD[@]}" "https://api.github.com/rate_limit" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "https://api.github.com/rate_limit" "$response_headers"
    remaining=$(jq -r '.resources.core.remaining' response.tmp)
    rm -f headers.tmp response.tmp

    if [ "$remaining" -gt 3 ]; then
        mkdir -p "assets/$SOURCE"
        rm "assets/$SOURCE/.data" "assets/.data" &> /dev/null

        update_sources_json

        source <(get_all_sources | jq -r --arg SOURCE "$SOURCE" '
            .[] | select(.source == $SOURCE) |
            "REPO=\(.repository)",
            (
                .api // empty |
                (
                    (.json // empty | "JSON_URL=\(.)"),
                    (.version // empty | "VERSION_URL=\(.)")
                )
            )
            '
        )

        if [ -n "$VERSION_URL" ]; then
            "${CURL_CMD[@]}" "$VERSION_URL" > response.tmp
            response_headers=$(<headers.tmp)
            log_github_api_request "$VERSION_URL" "$response_headers"
            if VERSION=$(jq -r '.version' response.tmp 2> /dev/null); then
                PATCHES_API_URL="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
            else
                rm -f headers.tmp response.tmp
                notify msg "Unable to fetch latest version from API!!\nRetry later."
                return 1
            fi
            rm -f headers.tmp response.tmp
        else
            if [ "$USE_PRE_RELEASE" == "on" ]; then
                PATCHES_API_URL="https://api.github.com/repos/$REPO/releases"
            else
                PATCHES_API_URL="https://api.github.com/repos/$REPO/releases/latest"
            fi
        fi

        "${CURL_CMD[@]}" "$PATCHES_API_URL" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "$PATCHES_API_URL" "$response_headers"
        
        local PATCHES_EXT
        PATCHES_EXT=$(get_patches_extension_from_api "response.tmp")
        
        if ! jq -r --arg ext "$PATCHES_EXT" '
                if type == "array" then .[0] else . end |
            "PATCHES_VERSION='\''\(.tag_name)'\''",
            "PATCHES_EXT='\''" + $ext + "'\''",
            (
                .assets[] |
                select(
                    (.name | endswith(".asc") | not) and
                    (.name | endswith(".json") | not)
                ) |
                if (.name | endswith("." + $ext)) then
                    "PATCHES_URL='\''\(.browser_download_url)'\''",
                    "PATCHES_SIZE='\''\(.size|tostring)'\''"
                else
                    "ASSET_URL_\(.name | gsub("[^a-zA-Z0-9_]"; "_"))='\''\(.browser_download_url)'\''",
                    "ASSET_SIZE_\(.name | gsub("[^a-zA-Z0-9_]"; "_"))='\''\(.size|tostring)'\''",
                    "ASSET_NAME_\(.name | gsub("[^a-zA-Z0-9_]"; "_"))='\''\(.name)'\''"
                end
            )
        ' response.tmp > "assets/$SOURCE/.data" 2>/dev/null; then
            rm -f headers.tmp response.tmp
            notify msg "Unable to fetch latest Patches info from API!!\nRetry later."
            return 1
        fi
        rm -f headers.tmp response.tmp

        [ -n "$JSON_URL" ] && setEnv JSON_URL "$JSON_URL" init "assets/$SOURCE/.data"
        
        source "assets/$SOURCE/.data"
        
        local CLI_API_URL
        if [ "$PATCHES_EXT" == "mpp" ]; then
            if [ "$USE_PRE_RELEASE" == "on" ]; then
                CLI_API_URL="https://api.github.com/repos/MorpheApp/morphe-cli/releases"
            else
                CLI_API_URL="https://api.github.com/repos/MorpheApp/morphe-cli/releases/latest"
            fi
        else
            if [ "$USE_PRE_RELEASE" == "on" ]; then
                CLI_API_URL="https://api.github.com/repos/inotia00/revanced-cli/releases"
            else
                CLI_API_URL="https://api.github.com/repos/inotia00/revanced-cli/releases/latest"
            fi
        fi

        "${CURL_CMD[@]}" "$CLI_API_URL" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "$CLI_API_URL" "$response_headers"
        if ! jq -r '
                if type == "array" then .[0] else . end |
            "CLI_VERSION='\''\(.tag_name)'\''",
            (
                .assets[] |
                if (.name | endswith(".jar")) then
                    "CLI_URL='\''\(.browser_download_url)'\''",
                    "CLI_SIZE='\''\(.size|tostring)'\''"
                else
                    empty
                end
            )
        ' response.tmp > assets/.data 2>/dev/null; then
            rm -f headers.tmp response.tmp
            notify msg "Unable to fetch latest CLI info from API!!\nRetry later."
            return 1
        fi
        rm -f headers.tmp response.tmp
    else
        notify msg "Unable to check for update.\nYou are probably rate-limited at this moment.\nTry again later or Run again with '-o' argument."
        return 1
    fi
    
    source "assets/.data"
    source "assets/$SOURCE/.data"
}

fetchAssets() {
    local CTR

    if [ -e "assets/.data" ] && [ -e "assets/$SOURCE/.data" ]; then
        source "assets/.data"
        source "assets/$SOURCE/.data"
    else
        fetchAssetsInfo || return 1
    fi

    if [ -z "$PATCHES_EXT" ]; then
        PATCHES_EXT=$(get_patches_extension "$SOURCE")
    fi

    PATCHES_FILE="assets/$SOURCE/Patches-$PATCHES_VERSION.$PATCHES_EXT"
    [ -e "$PATCHES_FILE" ] || rm -- assets/"$SOURCE"/Patches-* &> /dev/null

    CTR=3 && while [ "$PATCHES_SIZE" != "$(stat -c %s "$PATCHES_FILE" 2>/dev/null)" ]; do
        [ $CTR -eq 0 ] && notify msg "Oops! Unable to download completely.\n\nRetry or change your Network." && return 1
        ((CTR--))

        local patches_text="File    : Patches-$PATCHES_VERSION.$PATCHES_EXT\n"
        patches_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$PATCHES_SIZE")\n"
        patches_text+="\nDownloading..."

        downloadFile "$PATCHES_URL" "$PATCHES_FILE" "$PATCHES_SIZE" "$patches_text"
        tput civis
    done

    for var in $(compgen -v | grep "^ASSET_URL_"); do
        local name_var="${var/URL/NAME}"
        local size_var="${var/URL/SIZE}"
        local asset_url="${!var}"
        local asset_name="${!name_var}"
        local asset_size="${!size_var}"
        
        [ -z "$asset_name" ] && continue
        
        local asset_file="assets/$SOURCE/$asset_name"
        
        CTR=3 && while [ "$asset_size" != "$(stat -c %s "$asset_file" 2>/dev/null)" ]; do
            [ $CTR -eq 0 ] && notify msg "Oops! Unable to download $asset_name completely.\n\nRetry or change your Network." && return 1
            ((CTR--))

            local asset_text="File    : $asset_name\n"
            asset_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$asset_size")\n"
            asset_text+="\nDownloading..."

            downloadFile "$asset_url" "$asset_file" "$asset_size" "$asset_text"
            tput civis
        done
    done

    CLI_FILE="assets/CLI-$CLI_VERSION.jar"
    [ -e "$CLI_FILE" ] || rm -- assets/CLI-* &> /dev/null

    CTR=3 && while [ "$CLI_SIZE" != "$(stat -c %s "$CLI_FILE" 2> /dev/null)" ]; do
        [ $CTR -eq 0 ] && notify msg "Oops! Unable to download completely.\n\nRetry or change your Network." && return 1
        ((CTR--))

        local cli_text="File    : CLI-$CLI_VERSION.jar\n"
        cli_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$CLI_SIZE")\n"
        cli_text+="\nDownloading..."

        downloadFile "$CLI_URL" "$CLI_FILE" "$CLI_SIZE" "$cli_text"
        tput civis
    done

    parsePatchesJson || return 1
}

deleteAssets() {
    if "${DIALOG[@]}" \
            --title '| Delete Assets |' \
            --defaultno \
            --yesno "Please confirm to delete the assets.\nIt will delete the CLI and patches." -1 -1 \
    ; then
        unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL PATCHES_EXT
        for var in $(compgen -v | grep "^ASSET_"); do
            unset "$var"
        done
        rm -rf assets &> /dev/null
        rm -rf patch &> /dev/null
        rm -f "$CLI_DETECTION_FILE" &> /dev/null
        mkdir assets
    fi
}
