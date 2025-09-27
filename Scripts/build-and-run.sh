#!/bin/bash

# Build and run script for WonderWhisper Mac
# Builds the project and then launches the application

set -e  # Exit on any error

echo "Building and running WonderWhisper Mac..."

# Build the project
echo "Step 1: Building project..."
./Scripts/build.sh

# Run the application
echo "Step 2: Launching application..."
./Scripts/run.sh

echo "Build and run completed successfully!"
