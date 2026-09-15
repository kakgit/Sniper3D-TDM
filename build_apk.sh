#!/bin/sh
# Temporary build helper. Runs the Android export through the engine binary.

PROJ="D:/Game Projects/TDM/new-game-project"
ENG="/c/Users/SHC/AppData/Local/SummerEngine/current/Summer.exe"

echo "--- preflight ---"
pwd
if [ -f "main.tscn" ]; then echo "MAIN_TSCN_OK"; else echo "MAIN_TSCN_MISSING"; fi
if [ -f "$ENG" ]; then echo "ENGINE_FOUND"; else echo "ENGINE_MISSING at $ENG"; fi

mkdir -p "build"
if [ -d "build" ]; then echo "BUILD_DIR_OK"; else echo "BUILD_DIR_FAIL"; fi

echo "--- export ---"
"$ENG" --headless --path "$PROJ" --export-debug "Android" "$PROJ/build/tdm-sniper.apk"
echo "EXPORT_EXIT=$?"

echo "--- result ---"
ls -la "build"
