#!/usr/bin/bash

fetchAppsInfo() {
    local RESPONSE_JSON

    notify info "Fetching apps info from apkmirror.com..."

    if RESPONSE_JSON=$(
        "${CURL[@]}" 'https://www.apkmirror.com/wp-json/apkm/v1/app_exists/' \
            -A "$USER_AGENT" \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            -H 'Authorization: Basic YXBpLXRvb2xib3gtZm9yLWdvb2dsZS1wbGF5OkNiVVcgQVVMZyBNRVJXIHU4M3IgS0s0SCBEbmJL' \
            -d "$(jq -nr --argjson AVAILABLE_PATCHES "$AVAILABLE_PATCHES" '
                    {
                        "pnames": (
                            $AVAILABLE_PATCHES |
                            map(
                                .pkgName |
                                if . != null then
                                    .
                                else
                                    empty
                                end
                            )
                        )
                    }
                ')" |
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
