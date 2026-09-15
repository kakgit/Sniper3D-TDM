#!/bin/sh
ADB="/c/Users/SHC/AppData/Local/Android/Sdk/platform-tools/adb.exe"
APK="D:/Game Projects/TDM/new-game-project/build/tdm-sniper.apk"
PKG="com.tdm.sniperarena"

echo "--- device ---"
"$ADB" devices

echo "--- install ---"
"$ADB" install -r "$APK"
echo "INSTALL_EXIT=$?"

echo "--- verify package installed ---"
"$ADB" shell pm list packages | grep sniper || echo "PACKAGE_NOT_FOUND"
