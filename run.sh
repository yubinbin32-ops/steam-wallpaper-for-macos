#!/bin/bash
# Steam Wallpaper for Mac launcher
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "🚀 Building and launching Steam Wallpaper (Mac)..."
swift run WallpaperApp
