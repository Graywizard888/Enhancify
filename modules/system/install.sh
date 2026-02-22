installApp() {
    local CANONICAL_VER
    if [ "$ROOT_ACCESS" == true ]; then
        notify info "Initiating Mounting via Root Previlege..."
        sleep 1
        mountApp
    else
        local apk_path="apps/$APP_NAME/$APP_VER-$SOURCE.apk"
        local signed_apk_path="apps/$APP_NAME/$APP_VER-$SOURCE.apk"

        if [ "$Use_CUSTOM_KEYSTORE" == on ]; then
            notify info " Preparing To Sign with custom keystore..."
            sleep 1

            local keystore_dir="/data/data/com.termux/files/home/Enhancify/keystore"
            local keystore_json="$keystore_dir/keystore.json"
            local utils_dir="$HOME/Enhancify/utils"
            local apksigner_jar=$(find "$utils_dir" -name "apksigner*.jar" 2>/dev/null | head -1)
            local bc_jar=$(find "$utils_dir" -name "bcprov*.jar" 2>/dev/null | head -1)

            if [ -z "$apksigner_jar" ] || [ ! -f "$apksigner_jar" ]; then
                notify msg "apksigner JAR not found!\n\nExpected location:\n$utils_dir/apksigner.jar\n\nPlace the JAR file in that directory and try again."
                return 1
            fi

            if [ ! -d "$keystore_dir" ]; then
                notify msg "Keystore directory not found at: $keystore_dir"
                return 1
            fi

            if [ ! -f "$keystore_json" ]; then
                notify msg "Keystore JSON file not found at: $keystore_json"
                return 1
            fi

            local keystore_file=$(find "$keystore_dir" -maxdepth 1 -type f \( -name "*.jks" -o -name "*.p12" -o -name "*.pfx" -o -name "*.keystore" -o -name "*.jceks" -o -name "*.uber" \) | head -n1)

            if [ -z "$keystore_file" ]; then
                notify msg "No keystore file found in keystore directory!\n\nSupported formats: .jks, .p12, .pfx, .keystore, .jceks, .uber"
                return 1
            fi

            local keystore_filename=$(basename "$keystore_file")
            notify info "Using keystore: $keystore_filename"

            local alias_name=$(jq -r ".\"$keystore_filename\".alias // \"\"" "$keystore_json" 2>/dev/null)
            local keystore_pass=$(jq -r ".\"$keystore_filename\".keystore_password // \"\"" "$keystore_json" 2>/dev/null)
            local private_key_pass=$(jq -r ".\"$keystore_filename\".private_key_password // \"\"" "$keystore_json" 2>/dev/null)
            local keystore_type=$(jq -r ".\"$keystore_filename\".keystore_type // \"\"" "$keystore_json" 2>/dev/null)

            if [ -z "$alias_name" ] || [ "$alias_name" == "null" ]; then
                notify msg "Failed to retrieve alias from keystore.json for: $keystore_filename"
                return 1
            fi

            if [ -z "$keystore_pass" ] || [ "$keystore_pass" == "null" ]; then
                notify msg "Failed to retrieve keystore password from keystore.json for: $keystore_filename"
                return 1
            fi

            if [ -z "$private_key_pass" ] || [ "$private_key_pass" == "null" ]; then
                private_key_pass="$keystore_pass"
            fi

            if [ -z "$keystore_type" ] || [ "$keystore_type" == "null" ]; then
                local keystore_ext="${keystore_file##*.}"

                case "$keystore_ext" in
                    "jks") keystore_type="JKS" ;;
                    "p12"|"pfx") keystore_type="PKCS12" ;;
                    "jceks") keystore_type="JCEKS" ;;
                    "uber") keystore_type="UBER" ;;
                    "keystore")
                        notify info "Identifying Imported $keystore_filename Type..."
                        sleep 1
                        local keytool_output
                        keytool_output=$(keytool -list -v -keystore "$keystore_file" -storepass "$keystore_pass" 2>/dev/null)
                        if echo "$keytool_output" | grep -q "Keystore type:.*JKS"; then
                            keystore_type="JKS"
                            notify info "Detected keystore type: JKS"
                            sleep 1
                        elif echo "$keytool_output" | grep -q "Keystore type:.*PKCS12"; then
                            keystore_type="PKCS12"
                            notify info "Detected keystore type: PKCS12"
                            sleep 1
                        elif echo "$keytool_output" | grep -q "Keystore type:.*JCEKS"; then
                            keystore_type="JCEKS"
                            notify info "Detected keystore type: JCEKS"
                            sleep 1
                        else
                            local file_type
                            file_type=$(file "$keystore_file" 2>/dev/null)
                            if echo "$file_type" | grep -q "Java KeyStore"; then
                                keystore_type="JKS"
                                notify info "File analysis: Detected as JKS keystore"
                                sleep 1
                            elif echo "$file_type" | grep -q "PKCS12"; then
                                keystore_type="PKCS12"
                                notify info "File analysis: Detected as PKCS12 keystore"
                                sleep 1
                            else
                                keystore_type="JKS"
                                notify info "Could not determine keystore type, defaulting to JKS"
                                sleep 1
                            fi
                        fi
                        ;;
                    *)
                        notify msg "Unsupported keystore extension: .$keystore_ext"
                        return 1
                        ;;
                esac
            else
                notify info "Keystore type from config: $keystore_type"
                sleep 1
            fi

            if [ "$keystore_type" = "UBER" ]; then
                if [ -z "$bc_jar" ] || [ ! -f "$bc_jar" ]; then
                    notify msg "Bouncy Castle provider JAR not found!\n\nExpected location:\n$utils_dir/bcprov-*.jar\n\nPlace the JAR file in that directory and try again."
                    return 1
                fi
            fi

            notify info "Signing APK with $keystore_type keystore..."
            sleep 1

            local sign_output=""
            local sign_exit_code=0
            local keystore_pass_file=$(mktemp)
            local key_pass_file=$(mktemp)
            echo "$keystore_pass" > "$keystore_pass_file"
            echo "$private_key_pass" > "$key_pass_file"

            case "$keystore_type" in
                "JKS"|"PKCS12"|"JCEKS")
                    sign_output=$(java -jar "$apksigner_jar" sign \
                        --ks "$keystore_file" \
                        --ks-pass "file:$keystore_pass_file" \
                        --key-pass "file:$key_pass_file" \
                        --ks-type "$keystore_type" \
                        --ks-key-alias "$alias_name" \
                        --v1-signing-enabled true \
                        --v2-signing-enabled true \
                        --v3-signing-enabled true \
                        --v4-signing-enabled false \
                        --out "$signed_apk_path" \
                        "$apk_path" 2>&1)

                    sign_exit_code=$?
                    ;;

                "UBER")
                    notify info "Using Bouncy Castle provider:\n$(basename "$bc_jar")"
                    sleep 1

                    sign_output=$(java -cp "$apksigner_jar:$bc_jar" \
                        com.android.apksigner.ApkSignerTool sign \
                        --provider-class org.bouncycastle.jce.provider.BouncyCastleProvider \
                        --provider-pos 1 \
                        --ks "$keystore_file" \
                        --ks-pass "file:$keystore_pass_file" \
                        --key-pass "file:$key_pass_file" \
                        --ks-type "UBER" \
                        --ks-key-alias "$alias_name" \
                        --v1-signing-enabled true \
                        --v2-signing-enabled true \
                        --v3-signing-enabled true \
                        --v4-signing-enabled false \
                        --out "$signed_apk_path" \
                        "$apk_path" 2>&1)

                    sign_exit_code=$?
                    ;;

                *)
                    rm -f "$keystore_pass_file" "$key_pass_file"
                    notify msg "Unsupported keystore type: $keystore_type"
                    return 1
                    ;;
            esac

            rm -f "$keystore_pass_file" "$key_pass_file"

            if [ $sign_exit_code -eq 0 ]; then
                notify info "✓ APK signed successfully with custom $keystore_type keystore!"
                apk_path="$signed_apk_path"
            else
                local error_file=$(mktemp)
                if [ "$keystore_type" = "UBER" ]; then
                    echo -e "SIGNING FAILED\n\nKeystore: $keystore_filename\nType: UBER (Bouncy Castle)\nAlias: $alias_name\nProvider: BouncyCastleProvider\n\napksigner JAR: $(basename "$apksigner_jar")\nBC JAR: $(basename "$bc_jar")\n\n────────────────────────────────\nERROR OUTPUT:\n────────────────────────────────\n\n$sign_output" > "$error_file"
                else
                    echo -e "SIGNING FAILED\n\nKeystore: $keystore_filename\nType: $keystore_type\nAlias: $alias_name\n\napksigner JAR: $(basename "$apksigner_jar")\n\n────────────────────────────────\nERROR OUTPUT:\n────────────────────────────────\n\n$sign_output" > "$error_file"
                fi

                "${DIALOG[@]}" \
                    --title "| ✗ APK Signing Failed |" \
                    --textbox "$error_file" \
                    20 70 \
                    2>&1 >/dev/tty

                rm -f "$error_file"
                return 1
            fi
        else
            cp -f "$apk_path" "$signed_apk_path" &>/dev/null
            apk_path="$signed_apk_path"
        fi

        if [ "$RISH_ACCESS" == true ]; then
            notify info "Initiating Installation via Rish Previlege..."
            sleep 1
            installAppRish
        else
            notify info "No Previleges Detected\n\nCopying patched $APP_NAME apk to Internal Storage..."
            CANONICAL_VER=${APP_VER//:/}
            local final_apk_path="$STORAGE/Patched/$APP_NAME-$CANONICAL_VER-$SOURCE.apk"

            mkdir -p "$STORAGE/Patched"

            if cp -f "$apk_path" "$final_apk_path" &> /dev/null; then
                notify info "✓ APK copied successfully to: $final_apk_path"

                if [ -f "$signed_apk_path" ] && [ "$signed_apk_path" != "$apk_path" ]; then
                    rm -f "$signed_apk_path" &>/dev/null
                fi

                termux-open --view "$final_apk_path"
            else
                notify msg "✗ Failed to copy APK to Internal Storage!"
                return 1
            fi
        fi
    fi
    unset PKG_NAME APP_NAME APKMIRROR_APP_NAME APP_VER
}
