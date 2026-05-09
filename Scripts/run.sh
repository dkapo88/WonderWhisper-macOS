#!/bin/bash

# Run script for HermesWhisper
# Launches the built application from the Debug configuration

set -e  # Exit on any error

echo "Launching HermesWhisper..."
open "build/Build/Products/Debug/HermesWhisper.app"

echo "Application launched successfully!"
echo "You can also run the app directly from Xcode using the ▶︎ button"
