#!/bin/sh
ADB="/c/Users/SHC/AppData/Local/Android/Sdk/platform-tools/adb.exe"
PKG="com.tdm.sniperarena"
ACT="$PKG/com.godot.game.GodotAppLauncher"

"$ADB" logcat -c
echo "--- starting ---"
"$ADB" shell am start -n "$ACT"

sleep 20

echo "--- pid ---"
"$ADB" shell pidof "$PKG" || echo "NOT_ALIVE"

echo "--- godot lifecycle / fatal ---"
"$ADB" logcat -d -v brief 2>/dev/null | grep -iE "OnGodot|FATAL EXCEPTION|ANR in" | tail -15
echo "SCAN_DONE"
