#!/usr/bin/bash

fetchAppsInfo() {
    local RESPONSE_JSON PKG_NAMES BATCH_JSON BATCH_RESPONSE
    local -i TOTAL BATCH_SIZE=100 IDX=0 HAD_FAILURE=0

    notify info "Fetching apps info from apkmirror.com..."

    # apkmirror's app_exists API rejects requests with more than 100 pnames,
    # so large patch sets (e.g. rushiranpise) must be queried in batches.
    PKG_NAMES=$(jq -c '[.[] | .pkgName | select(. != null)]' <<< "$AVAILABLE_PATCHES")
    TOTAL=$(jq 'length' <<< "$PKG_NAMES")
    RESPONSE_JSON="[]"

    while [ "$IDX" -lt "$TOTAL" ]; do
        BATCH_JSON=$(jq -c --argjson i "$IDX" --argjson n "$BATCH_SIZE" '.[$i:($i+$n)]' <<< "$PKG_NAMES")

        if BATCH_RESPONSE=$(
            "${CURL[@]}" 'https://www.apkmirror.com/wp-json/apkm/v1/app_exists/' \
                -A "$USER_AGENT" \
                -H 'Accept: application/json' \
                -H 'Content-Type: application/json' \
                -H 'Authorization: Basic YXBpLXRvb2xib3gtZm9yLWdvb2dsZS1wbGF5OkNiVVcgQVVMZyBNRVJXIHU4M3IgS0s0SCBEbmJL' \
                -d "$(jq -nc --argjson PNAMES "$BATCH_JSON" '{"pnames": $PNAMES}')" |
                jq -c '
                    reduce .data[] as {
                        pname: $PKG_NAME,
                        exists: $EXISTS,
                        app: {
                            name: $APP_NAME,
                            link: $APP_URL
                        }
                    } (
                        [];
                        if $EXISTS then
                            . += [{
                                "pkgName": $PKG_NAME,
                                "appName": $APP_NAME,
                                "appUrl": $APP_URL
                            }]
                        else
                            .
                        end
                    )
                ' 2> /dev/null
        ); then
            RESPONSE_JSON=$(jq -c -n --argjson acc "$RESPONSE_JSON" --argjson batch "$BATCH_RESPONSE" '$acc + $batch' 2> /dev/null)
        else
            HAD_FAILURE=1
        fi

        IDX+=BATCH_SIZE
    done

    if [ "$HAD_FAILURE" -eq 0 ] || [ "$RESPONSE_JSON" != "[]" ]; then
        rm assets/"$SOURCE"/Apps-*.json &> /dev/null

        echo "$RESPONSE_JSON" |
            jq -c '
                reduce .[] as {pkgName: $PKG_NAME, appName: $APP_NAME, appUrl: $APP_URL} (
                    [];
                    . += [{
                        "pkgName": $PKG_NAME,
                        "appName": (
                                $APP_NAME |
                                sub("( -)|( &amp;)|:"; ""; "g") |
                                sub("[()\\|]"; ""; "g") |
                                sub(" *[-, ] *"; "-"; "g") |
                                sub("-Wear-OS|-Android-Automotive"; ""; "g")
                            ) |
                            split("-")[:4] |
                            join("-"),
                        "apkmirrorAppName": (
                                $APP_URL |
                                sub("-wear-os|-android-automotive"; "") |
                                match("(?<=\\/)(((?!\\/).)*)(?=\\/$)").string
                            ),
                    }]
                )
            ' > "assets/$SOURCE/Apps-$PATCHES_VERSION.json" \
                2> /dev/null
    else
        dialog --backtitle 'enhancify' --defaultno \
            --yesno "API request failed for apkmirror.com.\nTry again later... or\nDo you want to import app anyway?" 12 45

        case $? in
            0)  # User selected Yes
                TASK="IMPORT_APP"
                while true; do
                    case "$TASK" in
                        "IMPORT_APP")
                            if importApp; then
                                TASK="MANAGE_PATCHES"
                            else
                                break
                            fi
                            ;;
                        "MANAGE_PATCHES")
                            if managePatches; then
                                TASK="EDIT_OPTIONS"
                            else
                                break
                            fi
                            ;;
                        "EDIT_OPTIONS")
                            if editOptions; then
                                TASK="PATCH_APP"
                            else
                                break
                            fi
                            ;;
                        "PATCH_APP")
                            if patchApp; then
                                TASK="INSTALL_APP"
                            else
                                break
                            fi
                            ;;
                        "INSTALL_APP")
                            installApp
                            break
                            ;;
                    esac
                done
                ;;
            *)  # User selected No or exited
                return 1
                ;;
        esac
    fi
}
