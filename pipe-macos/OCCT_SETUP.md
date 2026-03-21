# OpenCASCADE Integration Setup Guide

This guide explains how to properly configure your Xcode project to work with OpenCASCADE (OCCT) for STEP file parsing.

## Prerequisites

1. **Install OpenCASCADE** via Homebrew:
```bash
brew install opencascade
```

This typically installs OCCT to `/opt/homebrew/Cellar/opencascade/` on Apple Silicon Macs or `/usr/local/Cellar/opencascade/` on Intel Macs.

## Xcode Project Configuration

### 1. Add Bridging Header

1. In Xcode, go to your target's **Build Settings**
2. Search for "Objective-C Bridging Header"
3. Set the value to: `$(PROJECT_DIR)/pipe-macos-Bridging-Header.h` (or the actual path to the bridging header file)

### 2. Configure Header Search Paths

In **Build Settings** → **Search Paths** → **Header Search Paths**, add:

```
/opt/homebrew/opt/opencascade/include/opencascade
```

Or for Intel Macs:
```
/usr/local/opt/opencascade/include/opencascade
```

Make sure this is set for **both Debug and Release** configurations.

### 3. Configure Library Search Paths

In **Build Settings** → **Search Paths** → **Library Search Paths**, add:

```
/opt/homebrew/opt/opencascade/lib
```

Or for Intel Macs:
```
/usr/local/opt/opencascade/lib
```

### 4. Link OpenCASCADE Libraries

In **Build Settings** → **Linking** → **Other Linker Flags**, add:

```
-lTKernel -lTKMath -lTKBRep -lTKGeomBase -lTKGeomAlgo -lTKTopAlgo -lTKPrim -lTKG3d -lTKG2d -lTKSTEP -lTKXSBase -lTKSTEP209 -lTKSTEPBase -lTKSTEPAttr
```

Or you can link them in the **General** tab → **Frameworks and Libraries**:
1. Click the "+" button
2. Click "Add Other..." → "Add Files..."
3. Navigate to `/opt/homebrew/opt/opencascade/lib/`
4. Select all the `.dylib` files mentioned above

### 5. Add Files to Project

Make sure these files are added to your target:
- `STEPBridge.h`
- `STEPBridge.mm` (Objective-C++ implementation)
- `STEPBridgeWrapper.h`
- `STEPBridgeWrapper.m` (Pure Objective-C wrapper)
- `pipe-macos-Bridging-Header.h`
- `ModelLoader.swift`

### 6. Enable C++ and Objective-C++ Compilation

In **Build Settings**:
1. Search for "C++ Language Dialect"
2. Set to: **GNU++17** or **C++17**
3. Search for "C++ Standard Library"
4. Set to: **libc++** (default on modern Xcode)

## Architecture Notes

### Why Three Layers?

1. **STEPBridge.mm** (Objective-C++)
   - Directly interfaces with C++ OpenCASCADE library
   - Cannot be imported directly into Swift

2. **STEPBridgeWrapper.m** (Pure Objective-C)
   - Acts as a pure Objective-C wrapper around STEPBridge
   - Can be exposed to Swift via bridging header
   - Converts OCCT results to JSON strings for easy Swift parsing

3. **ModelLoader.swift** (Swift)
   - Calls STEPBridgeWrapper through the bridging header
   - Parses JSON results and creates Swift model objects

## Troubleshooting

### Error: "STEPBridgeWrapper class not found"

**Solution**: Make sure the bridging header path is correctly set in Build Settings.

### Error: "'Standard_Real.hxx' file not found"

**Solution**: Check that Header Search Paths includes the OCCT include directory.

### Error: Undefined symbols for architecture arm64

**Solution**: 
1. Verify Library Search Paths includes the OCCT lib directory
2. Check that all required OCCT libraries are linked
3. Make sure you're building for the correct architecture (arm64 for Apple Silicon)

### Error: "Failed to read STEP file"

**Possible causes**:
1. File doesn't exist at the specified path
2. File is corrupted or not a valid STEP file
3. STEP file uses unsupported features (very rare)

### Error: "No shapes found in STEP file"

**Solution**: The STEP file may be empty or contain only non-solid geometry. Check the file in a CAD viewer.

## Testing the Integration

To verify OCCT is working:

1. Place a valid STEP file in a test location
2. Load it using `ModelLoader.load(url: fileURL)`
3. Check console output for success/error messages
4. If successful, you should see parsed B-Rep data

## Performance Considerations

- STEP parsing can be slow for complex files (>1MB)
- Consider showing a progress indicator for large files
- The JSON serialization adds overhead; for production, consider using native Swift objects directly

## Alternative: Build OpenCASCADE from Source

If you need custom OCCT configuration:

```bash
# Clone OCCT
git clone https://github.com/Open-Cascade-SAS/OCCT.git
cd OCCT

# Build with CMake
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/usr/local/opencascade \
         -DBUILD_LIBRARY_TYPE=Shared

make -j8
sudo make install
```

Then update your Xcode paths to point to `/usr/local/opencascade`.
