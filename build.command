#!/bin/bash
# Dubbelklicka för att bygga och installera Filmklipparen.
cd "$(dirname "$0")"
./build.sh "$@" 2>&1 | tee build.log
echo
read -n 1 -s -r -p "Tryck på en tangent för att stänga."
