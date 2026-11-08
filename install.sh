#!/bin/sh
# Собрать, положить в ~/Applications, прописать автозапуск при входе и запустить.
# launchd держит таймер живым: после крэша или выхода поднимает его снова (KeepAlive).
# Удалить: ./install.sh --uninstall
set -e
cd "$(dirname "$0")"
LABEL=com.ivanevtushenko.timer
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/Applications/Timer.app"

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    pkill -x Timer 2>/dev/null || true
    rm -f "$PLIST"; rm -rf "$DEST"
    echo "удалено (лог time_log.csv не тронут)"; exit 0
fi

./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Timer 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST" && cp -R build/Timer.app "$DEST"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/Timer</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ok: $DEST запущен, автозапуск при входе — $PLIST"
