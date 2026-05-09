#!/bin/bash

# Build and run script for HermesWhisper
# Builds the project and then launches the application

set -e  # Exit on any error

echo "Building and running HermesWhisper..."

# Build the project
echo "Step 1: Building project..."
./Scripts/build.sh

# Run the application
echo "Step 2: Launching application..."
./Scripts/run.sh

echo "Build and run completed successfully!"
