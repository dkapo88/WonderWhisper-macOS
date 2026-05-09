#!/bin/bash

# Build script for HermesWhisper
# Builds the project in Debug configuration

set -e  # Exit on any error

echo "Building HermesWhisper..."
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug -derivedDataPath build/ build

echo "Build completed successfully!"
echo "Build artifacts are located in the build/ directory"
