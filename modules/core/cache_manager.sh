#!/usr/bin/bash

CACHE_DIR="$HOME/Enhancify/apps_meta"

cache_metadata_manager() {
    local app_name="$1"
    local action="$2"
    local data="$3"
    local current_page_limit="$4"
    
    local safe_name="${app_name//[^a-zA-Z0-9_-]/_}"
    local cache_file="${CACHE_DIR}/${safe_name}_metadata.json"
    
    mkdir -p "$CACHE_DIR" 2>/dev/null
    
    case "$action" in
        "exists")
            if [[ -f "$cache_file" ]]; then
                if jq -e '.versions | type == "array" and length > 0' "$cache_file" &>/dev/null; then
                    local cached_page_limit
                    cached_page_limit=$(jq -r '.page_limit // 0' "$cache_file" 2>/dev/null)
                    if [[ -n "$current_page_limit" ]] && [[ "$current_page_limit" -gt "$cached_page_limit" ]]; then
                        return 1
                    fi
                    return 0
                fi
            fi
            return 1
            ;;
        "read")
            if [[ -f "$cache_file" ]]; then
                jq -c '.versions' "$cache_file" 2>/dev/null
            else
                echo "[]"
            fi
            ;;
        "write")
            local page_limit="$4"
            if jq -e 'type == "array"' <<< "$data" &>/dev/null; then
                jq -n \
                    --arg app_name "$app_name" \
                    --arg cached_at "$(date '+%Y-%m-%d')" \
                    --argjson page_limit "${page_limit:-5}" \
                    --argjson versions "$data" \
                    '{
                        app_name: $app_name,
                        cached_at: $cached_at,
                        page_limit: $page_limit,
                        version_count: ($versions | length),
                        versions: $versions
                    }' > "$cache_file"
                return $?
            fi
            return 1
            ;;
        "clear")
            rm -f "$cache_file" 2>/dev/null
            ;;
        "timestamp")
            if [[ -f "$cache_file" ]]; then
                jq -r '.cached_at // "Unknown"' "$cache_file" 2>/dev/null
            else
                echo "Not cached"
            fi
            ;;
        "page_limit")
            if [[ -f "$cache_file" ]]; then
                jq -r '.page_limit // 0' "$cache_file" 2>/dev/null
            else
                echo "0"
            fi
            ;;
    esac
}
