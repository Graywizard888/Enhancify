#!/usr/bin/bash

MIN_HEAP=1024

getJavaVersion() {
    local VERSION
    VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)

    VERSION="${VERSION//[!0-9]/}"

    [ -z "$VERSION" ] && VERSION=0

    echo "$VERSION"
}

checkJavaVersion() {
    local JAVA_VER
    JAVA_VER=$(getJavaVersion)

    if [ "$JAVA_VER" -eq 17 ] || [ "$JAVA_VER" -eq 21 ]; then
        return 0
    else
        return 1
    fi
}

getJavaFullVersion() {
    java -version 2>&1 | head -n 1
}

getAvailableMemory() {
    local MEM
    MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')

    if [ -z "$MEM" ] || [ "$MEM" -eq 0 ]; then
        MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $4}')
    fi

    [ -z "$MEM" ] && MEM=1024

    echo "$MEM"
}

getTotalMemory() {
    free -m 2>/dev/null | awk '/^Mem:/{print $2}'
}

calculateHeapSize() {
    local AVAILABLE_MEM HEAP_SIZE MAX_HEAP
    AVAILABLE_MEM=$(getAvailableMemory)

    MAX_HEAP=$((AVAILABLE_MEM * 75 / 100))

    HEAP_SIZE=$MAX_HEAP

    [ "$HEAP_SIZE" -lt "$MIN_HEAP" ] && HEAP_SIZE=$MIN_HEAP

    echo "$HEAP_SIZE"
}

getMaxHeap() {
    local AVAILABLE_MEM MAX_HEAP
    AVAILABLE_MEM=$(getAvailableMemory)
    MAX_HEAP=$((AVAILABLE_MEM * 75 / 100))
    [ "$MAX_HEAP" -lt "$MIN_HEAP" ] && MAX_HEAP=$MIN_HEAP
    echo "$MAX_HEAP"
}

checkMemory() {
    AVAILABLE_MEM=$(getAvailableMemory)

    if [ "$AVAILABLE_MEM" -lt "$MIN_HEAP" ]; then
        "${DIALOG[@]}" \
            --title '| Low Memory Warning |' \
            --yesno "\nLow memory detected!\n\n  Available : ${AVAILABLE_MEM}MB\n  Required  : ${MIN_HEAP}MB\n\nPatching may fail due to insufficient memory.\n\nRecommendations:\n • Close background apps\n • Restart Termux\n • Free up RAM\n\nDo you still want to continue anyway?" 18 50

        case "$?" in
            0) return 0 ;;
            *) return 1 ;;
        esac
    fi

    return 0
}

buildJavaArgs() {
    local HEAP_SIZE="$1"
    local JAVA_VER
    local CPU_CORES

    JAVA_VER=$(getJavaVersion)
    CPU_CORES=$(nproc 2>/dev/null || echo 6)

    PARALLEL_GC_THREADS=$CPU_CORES
    CONC_GC_THREADS=$((CPU_CORES / 4))
    [ $CONC_GC_THREADS -lt 2 ] && CONC_GC_THREADS=2

    JAVA_ARGS=(
        "-Xmx${HEAP_SIZE}m"
        "-Xms$((HEAP_SIZE / 3))m"
        "-Djava.io.tmpdir=$TMPDIR"
        "-XX:-UsePerfData"
    )

    if [ "$JAVA_VER" -eq 17 ] || [ "$JAVA_VER" -eq 21 ]; then
        JAVA_ARGS+=(
            "-XX:+UseG1GC"
            "-XX:MaxGCPauseMillis=150"
            "-XX:G1HeapRegionSize=2m"
            "-XX:+UseStringDeduplication"
            "-XX:+ParallelRefProcEnabled"
            "-XX:ConcGCThreads=$CONC_GC_THREADS"
            "-XX:ParallelGCThreads=$PARALLEL_GC_THREADS"
            "-XX:CICompilerCount=3"
            "-XX:+UseCompressedOops"
            "-XX:+UseCompressedClassPointers"
            "-XX:+OptimizeStringConcat"
            "-XX:+DisableExplicitGC"
            "-XX:+TieredCompilation"
            "-XX:ReservedCodeCacheSize=128m"
            "-XX:InitialCodeCacheSize=32m"
            "-XX:MaxMetaspaceSize=128m"
            "-XX:SoftRefLRUPolicyMSPerMB=50"
        )
    fi

    printf '%s\n' "${JAVA_ARGS[@]}"
}

buildLightweightJavaArgs() {
    local HEAP_SIZE="$1"

    JAVA_ARGS=(
        "-Xmx${HEAP_SIZE}m"
        "-Xms128m"
        "-Djava.io.tmpdir=$TMPDIR"
        "-XX:+UseSerialGC"
        "-XX:TieredStopAtLevel=1"
        "-XX:+UseCompressedOops"
        "-XX:-UsePerfData"
        "-XX:CICompilerCount=1"
        "-XX:ReservedCodeCacheSize=32m"
    )

    printf '%s\n' "${JAVA_ARGS[@]}"
}

findPatchedApp() {
    if [ -e "apps/$APP_NAME/$APP_VER-$SOURCE.apk" ]; then
        "${DIALOG[@]}" \
            --title '| Patched apk found |' \
            --defaultno \
            --yes-label 'Patch' \
            --no-label 'Install' \
            --help-button \
            --help-label 'Back' \
            --yesno "Current directory already contains Patched $APP_NAME version $APP_VER.\n\n\nDo you want to patch $APP_NAME again?" -1 -1
        case "$?" in
            0)
                rm "apps/$APP_NAME/$APP_VER-$SOURCE.apk"
                ;;
            1)
                TASK="INSTALL_APP"
                return 1
                ;;
            2)
                return 1
                ;;
        esac
    else
        return 0
    fi
}

patchApp() {
    if [ ! -e "apps/$APP_NAME/$APP_VER.apk" ]; then
        notify msg "Apk not found !!\nTry importing Apk from Storage."
        return 1
    fi

    JAVA_VER=$(getJavaVersion)
    JAVA_FULL_VER=$(getJavaFullVersion)

    if ! checkJavaVersion; then
        "${DIALOG[@]}" \
            --title '| Java Version Warning |' \
            --yesno "\nUnsupported Java version detected!\n\nDetected: Java $JAVA_VER\nSupported: OpenJDK 17 or 21\n\nScript is optimized for OpenJDK 17/21.\nContinue with current Java?" 14 50

        case "$?" in
            0) ;;
            *) return 1 ;;
        esac
    fi

    if ! checkMemory; then
        notify msg "Patching cancelled due to low memory."
        return 1
    fi

    HEAP_SIZE=$(calculateHeapSize)
    MAX_HEAP=$(getMaxHeap)
    AVAILABLE_MEM=$(getAvailableMemory)
    TOTAL_MEM=$(getTotalMemory)
    CPU_CORES=$(nproc 2>/dev/null || echo 6)

    if [ "$AVAILABLE_MEM" -lt "$MIN_HEAP" ]; then
        readarray -t JAVA_ARGS < <(buildLightweightJavaArgs "$HEAP_SIZE")
        GC_INFO="SerialGC (Low Memory Mode)"
    else
        readarray -t JAVA_ARGS < <(buildJavaArgs "$HEAP_SIZE")
        GC_INFO="G1GC (Optimized for JDK $JAVA_VER)"
    fi

    readarray -t ARGUMENTS < <(
        jq -nrc --arg PKG_NAME "$PKG_NAME" --argjson ENABLED_PATCHES "$ENABLED_PATCHES" '
            $ENABLED_PATCHES[] |
            select(.pkgName == $PKG_NAME) |
            .options as $OPTIONS |
            .patches[] |
            . as $PATCH_NAME |
            "--enable",
            $PATCH_NAME,
            (
                $OPTIONS[] |
                if .patchName == $PATCH_NAME then
                    "--options=" +
                    .key + "=" +
                    (
                        .value |
                        if . != null then
                            . | tostring
                        else
                            empty
                        end
                    )
                else
                    empty
                end
            )
        '
    )

    cat > "$STORAGE/patch_log.txt" << EOF
╔═════════════════════════════════╗
║       Enhancify PATCH LOG
╠═════════════════════════════════╣
║ Date: $(date)
╠═════════════════════════════════╣
║ SYSTEM INFO
╠═════════════════════════════════╣
║ Root Access   : $ROOT_ACCESS
║ Rish Access   : $RISH_ACCESS
║ Architecture  : $ARCH
║ CPU Cores     : $CPU_CORES
╠═════════════════════════════════╣
║ JAVA INFO
╠═════════════════════════════════╣
║ Java Version  : $JAVA_FULL_VER
║ Major Version : $JAVA_VER
║ GC Type       : $GC_INFO
╠═════════════════════════════════╣
║ MEMORY INFO
╠═════════════════════════════════╣
║ Total Memory  : ${TOTAL_MEM}MB
║ Available     : ${AVAILABLE_MEM}MB
║ Heap Size     : ${HEAP_SIZE}MB
║ Max Heap (75%): ${MAX_HEAP}MB
║ Min Heap      : ${MIN_HEAP}MB
╠═════════════════════════════════╣
║ APP INFO
╠═════════════════════════════════╣
║ App Name      : $APP_NAME
║ App Version   : $APP_VER
║ Package       : $PKG_NAME
║ CLI           : $CLI_FILE
║ Patches       : $PATCHES_FILE
╠═════════════════════════════════╣
║ JVM ARGUMENTS
╠═════════════════════════════════╣
$(printf '║ %s\n' "${JAVA_ARGS[@]}")
╠═════════════════════════════════╣
║ PATCH ARGUMENTS
╠═════════════════════════════════╣
║ ${ARGUMENTS[*]}
╚═════════════════════════════════║

========================= PATCHING LOGS =========================

EOF

    java \
        "${JAVA_ARGS[@]}" \
        -jar "$CLI_FILE" patch \
        --force --exclusive --purge --patches="$PATCHES_FILE" \
        --out="apps/$APP_NAME/$APP_VER-$SOURCE.apk" \
        "${ARGUMENTS[@]}" \
        --custom-aapt2-binary="./bin/aapt2" \
        --keystore="$STORAGE/revancify.keystore" \
        "apps/$APP_NAME/$APP_VER.apk" 2>&1 |
        tee -a "$STORAGE/patch_log.txt" |
        "${DIALOG[@]}" \
            --ok-label 'Install & Save' \
            --extra-button \
            --extra-label 'Share Logs' \
            --cursor-off-label \
            --programbox "Patching $APP_NAME $APP_VER [JDK $JAVA_VER | ${HEAP_SIZE}MB]" -1 -1

    EXIT_CODE=$?
    tput civis

    if [ $EXIT_CODE -eq 3 ]; then
        termux-open --send "$STORAGE/patch_log.txt"
    fi

    if grep -qE "OutOfMemoryError|Cannot allocate memory|GC overhead limit exceeded|Java heap space" "$STORAGE/patch_log.txt"; then
        "${DIALOG[@]}" \
            --title '| Memory Error |' \
            --msgbox "\nPatching failed due to memory error!\n\n  Total RAM   : ${TOTAL_MEM}MB\n  Available   : ${AVAILABLE_MEM}MB\n  Heap Used   : ${HEAP_SIZE}MB\n  GC Type     : ${GC_INFO}\n\nSuggestions:\n • Close all background apps\n • Restart Termux\n • Restart device\n • Try fewer patches" 18 55
        return 1
    fi

        if [ $? -eq 1 ]; then
            termux-open --send "$STORAGE/patch_log.txt"
        fi

    if [ ! -f "apps/$APP_NAME/$APP_VER-$SOURCE.apk" ]; then
        notify msg "Patching failed !!\nInstallation Aborted.\n\nCheck logs for details."
        return 1
    fi

    return 0
}
