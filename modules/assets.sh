#!/usr/bin/bash

log_github_api_request() {
    local endpoint="$1"
    local response_headers="$2"
    
    local limit remaining reset
    limit=$(grep -i 'x-ratelimit-limit:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    remaining=$(grep -i 'x-ratelimit-remaining:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    reset=$(grep -i 'x-ratelimit-reset:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    
    local log_file="github_api_log.json"
    
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

fetchAssetsInfo() {
    unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL
    local SOURCE_INFO VERSION PATCHES_API_URL

    local CURL_CMD=("${CURL[@]}" \
        --compressed \
        --retry 3 \
        --retry-delay 1 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -D headers.tmp)

    internet || return 1

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        notify info "Initiating Network Acceleration ...\nFetching Assets Info"
    else
        notify info "Fetching Assets Info.."
    fi

    "${CURL_CMD[@]}" "https://api.github.com/rate_limit" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "https://api.github.com/rate_limit" "$response_headers"
    remaining=$(jq -r '.resources.core.remaining' response.tmp)
    rm -f headers.tmp response.tmp

    if [ "$remaining" -gt 3 ]; then
        mkdir -p "assets/$SOURCE"
        rm "assets/$SOURCE/.data" "assets/.data" &> /dev/null

        if [ "$USE_PRE_RELEASE" == "on" ]; then
            CLI_API_URL="https://api.github.com/repos/ReVanced/revanced-cli/releases"
        else
            CLI_API_URL="https://api.github.com/repos/ReVanced/revanced-cli/releases/latest"
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

        if [ "$USE_PRE_RELEASE" == "on" ]; then
            jq '
                (.[]
                | select(.source == "Anddea")
                | .api.json) |= sub("main"; "dev")
            ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
        else
            jq '
                (.[]
                | select(.source == "Anddea")
                | .api.json) |= sub("dev"; "main")
            ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
        fi

        if [ "$USE_PRE_RELEASE" == "on" ]; then
            jq '
                (.[]
                | select(.source == "ReVanced-Extended")
                | .api.json) |= sub("revanced-extended"; "dev")
            ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
        else
            jq '
                (.[]
                | select(.source == "ReVanced-Extended")
                | .api.json) |= sub("dev"; "revanced-extended")
            ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
        fi

        if [ "$USE_PRE_RELEASE" == "on" ]; then
            jq '
                (.[]
                | select(.source == "ReVancedExperiments")
                | .api.json) |= sub("ReVancedExperiments"; "dev")
            ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
        else
            jq '
                (.[]
                | select(.source == "ReVancedExperiments")
                | .api.json) |= sub("dev"; "ReVancedExperiments")
            ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
        fi

        source <(jq -r --arg SOURCE "$SOURCE" '
            .[] | select(.source == $SOURCE) |
            "REPO=\(.repository)",
            (
                .api // empty |
                (
                    (.json // empty | "JSON_URL=\(.)"),
                    (.version // empty | "VERSION_URL=\(.)")
                )
            )
            ' sources.json
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
        if ! jq -r '
                if type == "array" then .[0] else . end |
            "PATCHES_VERSION='\''\(.tag_name)'\''",
            (
                .assets[] |
                if (.name | endswith(".rvp")) then
                    "PATCHES_URL='\''\(.browser_download_url)'\''",
                    "PATCHES_SIZE='\''\(.size|tostring)'\''"
                else
                    empty
                end
            )
        ' response.tmp > "assets/$SOURCE/.data" 2>/dev/null; then
            rm -f headers.tmp response.tmp
            notify msg "Unable to fetch latest Patches info from API!!\nRetry later."
            return 1
        fi
        rm -f headers.tmp response.tmp

        [ -n "$JSON_URL" ] && setEnv JSON_URL "$JSON_URL" init "assets/$SOURCE/.data"
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

    PATCHES_FILE="assets/$SOURCE/Patches-$PATCHES_VERSION.rvp"
    [ -e "$PATCHES_FILE" ] || rm -- assets/"$SOURCE"/Patches-* &> /dev/null

    CTR=3 && while [ "$PATCHES_SIZE" != "$(stat -c %s "$PATCHES_FILE" 2>/dev/null)" ]; do
        [ $CTR -eq 0 ] && notify msg "Oops! Unable to download completely.\n\nRetry or change your Network." && return 1
        ((CTR--))

        local patches_text="File    : Patches-$PATCHES_VERSION.rvp\n"
        patches_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$PATCHES_SIZE")\n"
        patches_text+="\nDownloading..."

        downloadFile "$PATCHES_URL" "$PATCHES_FILE" "$PATCHES_SIZE" "$patches_text"
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
        unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL
        rm -rf assets &> /dev/null
        mkdir assets
    fi
}
