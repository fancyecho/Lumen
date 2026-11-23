#!/bin/bash
echo "Redirecting stderr to '/tmp/stderr.txt'"
echo "[  0%] Checking for available updates..."
echo "[ 45%] Downloading update (12,345 of 54,321 KB)..."
echo "Steam Console Client (c) Valve Corporation - version 1730000000"
echo "Logging in user 'tester' [U:1:0] to Steam Public..."
printf "password: "
read -s pw
echo
if [ "$pw" != "secret" ]; then echo "FAILED (Invalid Password)"; exit 5; fi
printf "Steam Guard code:"
read code
echo
if [ "$code" != "ABCDE" ]; then echo "FAILED (Invalid Login Auth Code)"; exit 5; fi
echo "OK"
echo "Waiting for client config...OK"
echo "Waiting for user info...OK"
DEST="$2/steamapps/workshop/content/431960/123456"
mkdir -p "$DEST"
echo "Downloading item 123456 ..."
echo "Success. Downloaded item 123456 to \"$DEST\" (100 bytes)"
