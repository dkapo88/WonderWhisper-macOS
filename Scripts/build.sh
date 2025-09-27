#!/bin/bash

# Build script for WonderWhisper Mac
# Builds the project in Debug configuration

set -e  # Exit on any error

echo "Building WonderWhisper Mac..."
xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug build

echo "Build completed successfully!"
echo "Build artifacts are located in the build/ directory"
