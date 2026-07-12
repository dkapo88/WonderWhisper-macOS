#!/bin/bash

# Build script for WonderWhisper
# Builds the project in Debug configuration

set -e  # Exit on any error

echo "Building WonderWhisper..."
xcodebuild -project "WonderWhisper.xcodeproj" -scheme "WonderWhisper" -configuration Debug -derivedDataPath build/ build

echo "Build completed successfully!"
echo "Build artifacts are located in the build/ directory"
