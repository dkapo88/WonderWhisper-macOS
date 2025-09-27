#!/bin/bash

# Run script for WonderWhisper Mac
# Launches the built application from the Debug configuration

set -e  # Exit on any error

echo "Launching WonderWhisper Mac..."
open "build/Build/Products/Debug/WonderWhisper Mac.app"

echo "Application launched successfully!"
echo "You can also run the app directly from Xcode using the ▶︎ button"
