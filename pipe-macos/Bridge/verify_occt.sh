#!/bin/bash
#
# verify_occt.sh
# Script to verify OpenCASCADE installation and setup
#

set -e

echo "=== OpenCASCADE Installation Verification ==="
echo ""

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew is not installed"
    echo "   Install from: https://brew.sh"
    exit 1
fi
echo "✅ Homebrew is installed"

# Check if OpenCASCADE is installed
if ! brew list opencascade &> /dev/null; then
    echo "❌ OpenCASCADE is not installed"
    echo "   Run: brew install opencascade"
    exit 1
fi
echo "✅ OpenCASCADE is installed via Homebrew"

# Get OCCT version
OCCT_VERSION=$(brew list --versions opencascade | awk '{print $2}')
echo "   Version: $OCCT_VERSION"

# Detect architecture
ARCH=$(uname -m)
echo "   Architecture: $ARCH"

# Determine the correct paths
if [ "$ARCH" = "arm64" ]; then
    OCCT_PREFIX="/opt/homebrew/opt/opencascade"
else
    OCCT_PREFIX="/usr/local/opt/opencascade"
fi

echo ""
echo "=== Checking OCCT Paths ==="

# Check include directory
INCLUDE_DIR="$OCCT_PREFIX/include/opencascade"
if [ -d "$INCLUDE_DIR" ]; then
    echo "✅ Include directory exists: $INCLUDE_DIR"
    HEADER_COUNT=$(find "$INCLUDE_DIR" -name "*.hxx" | wc -l)
    echo "   Found $HEADER_COUNT header files"
else
    echo "❌ Include directory not found: $INCLUDE_DIR"
    exit 1
fi

# Check lib directory
LIB_DIR="$OCCT_PREFIX/lib"
if [ -d "$LIB_DIR" ]; then
    echo "✅ Library directory exists: $LIB_DIR"
    DYLIB_COUNT=$(find "$LIB_DIR" -name "*.dylib" | wc -l)
    echo "   Found $DYLIB_COUNT dynamic libraries"
else
    echo "❌ Library directory not found: $LIB_DIR"
    exit 1
fi

echo ""
echo "=== Checking Required Libraries ==="
echo ""
echo "Note: OpenCASCADE 7.8.0+ uses TKDESTEP (modernized Data Exchange module)"
echo "      Older versions used: TKSTEP, TKSTEP209, TKSTEPBase, TKSTEPAttr"
echo ""

# Libraries required for OCCT 7.8.0+ (modernized library names)
REQUIRED_LIBS=(
    "TKernel"
    "TKMath"
    "TKBRep"
    "TKGeomBase"
    "TKGeomAlgo"
    "TKTopAlgo"
    "TKPrim"
    "TKG3d"
    "TKG2d"
    "TKDESTEP"      # Replaces TKSTEP, TKSTEP209, TKSTEPBase, TKSTEPAttr in 7.8+
    "TKXSBase"
)

ALL_FOUND=true
for lib in "${REQUIRED_LIBS[@]}"; do
    if ls "$LIB_DIR"/lib${lib}.*.dylib 1> /dev/null 2>&1; then
        echo "✅ $lib"
    else
        echo "❌ $lib (not found)"
        ALL_FOUND=false
    fi
done

if [ "$ALL_FOUND" = false ]; then
    echo ""
    echo "⚠️  Some required libraries are missing"
    echo ""
    echo "Checking if you have the old library names (OCCT < 7.8)..."
    
    OLD_LIBS=("TKSTEP" "TKSTEP209" "TKSTEPBase" "TKSTEPAttr")
    OLD_FOUND=false
    
    for lib in "${OLD_LIBS[@]}"; do
        if ls "$LIB_DIR"/lib${lib}.*.dylib 1> /dev/null 2>&1; then
            echo "   Found: $lib"
            OLD_FOUND=true
        fi
    done
    
    if [ "$OLD_FOUND" = true ]; then
        echo ""
        echo "⚠️  You have an older version of OpenCASCADE (< 7.8.0)"
        echo "   Update your linker flags to use the old library names:"
        echo "   -lTKSTEP -lTKSTEP209 -lTKSTEPBase -lTKSTEPAttr"
        echo ""
        echo "   Or upgrade to OCCT 7.8+: brew upgrade opencascade"
    else
        echo ""
        echo "   Try reinstalling: brew reinstall opencascade"
    fi
    exit 1
fi

echo ""
echo "=== Xcode Configuration Suggestions ==="
echo ""
echo "Add to Build Settings → Header Search Paths:"
echo "   $INCLUDE_DIR"
echo ""
echo "Add to Build Settings → Library Search Paths:"
echo "   $LIB_DIR"
echo ""
echo "Add to Build Settings → Other Linker Flags (for OCCT 7.8+):"
echo "   -lTKernel -lTKMath -lTKBRep -lTKGeomBase -lTKGeomAlgo -lTKTopAlgo -lTKPrim -lTKG3d -lTKG2d -lTKDESTEP -lTKXSBase"
echo ""
echo "Set Build Settings → Objective-C Bridging Header to:"
echo "   \$(PROJECT_DIR)/pipe-macos-Bridging-Header.h"
echo ""

echo "✅ All checks passed! OpenCASCADE $OCCT_VERSION is properly installed."
echo ""
echo "Next steps:"
echo "1. Configure Xcode build settings as shown above"
echo "2. Build the project"
echo "3. Test with a STEP file"
