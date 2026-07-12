#!/bin/bash

# Run script for WonderWhisper
# Launches the built application from the Debug configuration

set -e  # Exit on any error

echo "Launching WonderWhisper..."
open "build/Build/Products/Debug/WonderWhisper.app"

echo "Application launched successfully!"
echo "You can also run the app directly from Xcode using the ▶︎ button"
