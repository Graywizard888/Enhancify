#!/data/data/com.termux/files/usr/bin/bash
case "$PREFIX" in
    /data/data/com.termux/files/usr|/data/data/com.gwterm/files/usr) ;;
    *) echo -e "Termux/Shellterm not detected !!"; exit 1 ;;
esac
BIN="$PREFIX/bin/enhancify"
curl -sL "https://github.com/Graywizard888/Enhancify/raw/refs/heads/main/enhancify" -o "$BIN"
[ -e "$BIN" ] && sed -i "1s|.*|#!$PREFIX/bin/bash|" "$BIN" && chmod +x "$BIN" && "$BIN"
