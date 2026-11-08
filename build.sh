#!/bin/sh
# Сборка Timer.app без Xcode — хватает Command Line Tools (swiftc + clang).
set -e
cd "$(dirname "$0")"
APP=build/Timer.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
clang -c -fobjc-arc -O2 Sources/Touch.m -o build/Touch.o
swiftc -O -swift-version 5 -import-objc-header Sources/Bridging.h \
    Sources/main.swift build/Touch.o -framework AppKit -framework Carbon \
    -o "$APP/Contents/MacOS/Timer"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "ok: $APP"
