# Complete Setup Guide: OpenCASCADE 7.8+ Integration

This guide will walk you through setting up OpenCASCADE STEP parsing in your macOS app.

## Prerequisites

- macOS 13.0 or later
- Xcode 14 or later
- Homebrew package manager

## Part 1: Install OpenCASCADE

### Step 1: Install via Homebrew

```bash
brew install opencascade
```

This installs OpenCASCADE 7.9.3 (or latest available version).

### Step 2: Verify Installation

```bash
chmod +x verify_occt.sh
./verify_occt.sh
```

Expected output:
```
✅ Homebrew is installed
✅ OpenCASCADE is installed via Homebrew
   Version: 7.9.3
   Architecture: arm64
✅ Include directory exists: /opt/homebrew/opt/opencascade/include/opencascade
   Found 4500+ header files
✅ Library directory exists: /opt/homebrew/opt/opencascade/lib
   Found 100+ dynamic libraries
✅ TKernel
✅ TKMath
✅ TKBRep
...
✅ TKDESTEP
✅ TKXSBase
```

## Part 2: Configure Xcode Project

### Method A: Use xcconfig File (Recommended)

1. **Add OpenCASCADE.xcconfig to your project**:
   - Drag `OpenCASCADE.xcconfig` into your Xcode project
   - Don't add it to any target (it's a configuration file)

2. **Set the configuration**:
   - Select your project in Navigator
   - Click on the project (blue icon)
   - Go to "Info" tab
   - Under "Configurations", expand "Debug"
   - For your target, select "OpenCASCADE" from dropdown
   - Do the same for "Release"

3. **Verify architecture setting**:
   - Open `OpenCASCADE.xcconfig`
   - Check that `OCCT_PREFIX` is set correctly:
     - Apple Silicon: `OCCT_PREFIX = $(OCCT_PREFIX_ARM)`
     - Intel Mac: `OCCT_PREFIX = $(OCCT_PREFIX_X86)`

4. **Clean and build**:
   ```
   Product → Clean Build Folder (Cmd+Shift+K)
   Product → Build (Cmd+B)
   ```

### Method B: Manual Configuration

If you prefer to configure manually:

#### 1. Header Search Paths

Build Settings → Search Paths → Header Search Paths

**Apple Silicon**:
```
/opt/homebrew/opt/opencascade/include/opencascade
```

**Intel Mac**:
```
/usr/local/opt/opencascade/include/opencascade
```

#### 2. Library Search Paths

Build Settings → Search Paths → Library Search Paths

**Apple Silicon**:
```
/opt/homebrew/opt/opencascade/lib
```

**Intel Mac**:
```
/usr/local/opt/opencascade/lib
```

#### 3. Other Linker Flags

Build Settings → Linking → Other Linker Flags

**For OpenCASCADE 7.8+** (current):
```
-lTKernel -lTKMath -lTKBRep -lTKGeomBase -lTKGeomAlgo -lTKTopAlgo -lTKPrim -lTKG3d -lTKG2d -lTKDESTEP -lTKXSBase
```

#### 4. Bridging Header

Build Settings → Swift Compiler - General → Objective-C Bridging Header

```
$(PROJECT_DIR)/pipe-macos-Bridging-Header.h
```

Or if your project structure differs:
```
$(SRCROOT)/YourFolder/pipe-macos-Bridging-Header.h
```

#### 5. C++ Settings

Build Settings → Apple Clang - Language - C++

- **C++ Language Dialect**: `GNU++17` or `C++17`
- **C++ Standard Library**: `libc++`

Build Settings → Apple Clang - Language

- **Enable C++ Exceptions**: `YES`
- **Enable C++ Runtime Types**: `YES`

## Part 3: Add Files to Project

### Required Files

Make sure these files are in your project:

1. ✅ **STEPBridge.h** - C++ bridge header
2. ✅ **STEPBridge.mm** - C++ bridge implementation (Objective-C++)
3. ✅ **STEPBridgeWrapper.h** - Pure Objective-C wrapper header
4. ✅ **STEPBridgeWrapper.m** - Pure Objective-C wrapper implementation
5. ✅ **pipe-macos-Bridging-Header.h** - Swift bridging header
6. ✅ **ModelLoader.swift** - Swift model loader

### Verify Target Membership

For each file, check in File Inspector → Target Membership:

- **STEPBridge.h**: ✅ Your app target
- **STEPBridge.mm**: ✅ Your app target (compile as Objective-C++)
- **STEPBridgeWrapper.h**: ✅ Your app target
- **STEPBridgeWrapper.m**: ✅ Your app target
- **pipe-macos-Bridging-Header.h**: ❌ NO target (it's referenced by build settings)
- **ModelLoader.swift**: ✅ Your app target

### Verify Bridging Header Content

Open `pipe-macos-Bridging-Header.h` and ensure it contains:

```objectivec
#import "STEPBridgeWrapper.h"
```

## Part 4: Build and Test

### 1. Clean Build Folder

```
Product → Clean Build Folder (Cmd+Shift+K)
```

Or delete derived data:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData
```

### 2. Build Project

```
Product → Build (Cmd+B)
```

### 3. Resolve Any Build Errors

**Error: "Cannot find 'STEPBridgeWrapper' in scope"**
- Check bridging header path in Build Settings
- Verify `pipe-macos-Bridging-Header.h` exists and contains the import

**Error: "'Standard_Real.hxx' file not found"**
- Check Header Search Paths are set correctly
- Run `./verify_occt.sh` to see the correct path

**Error: "ld: library not found for -lTKDESTEP"**
- Verify Library Search Paths are set correctly
- Check OCCT is installed: `brew list opencascade`

**Other errors?** See QUICKFIX.md for common issues and solutions.

### 4. Test STEP Loading

Add this test code to your app:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Button("Load Test STEP File") {
                testSTEPLoading()
            }
        }
    }
    
    func testSTEPLoading() {
        // Replace with your actual STEP file path
        guard let url = Bundle.main.url(forResource: "test", withExtension: "step") else {
            print("❌ Test STEP file not found")
            return
        }
        
        do {
            let model = try ModelLoader.load(url: url)
            print("✅ Success! Loaded: \(model.name)")
            print("   Meshes: \(model.meshes.count)")
            print("   Vertices: \(model.vertexCount)")
            print("   Faces: \(model.faceCount)")
            if let stock = model.stockInfo {
                print("   Profile: \(stock.profile.rawValue)")
                print("   Length: \(stock.length)")
            }
        } catch {
            print("❌ Failed: \(error.localizedDescription)")
        }
    }
}
```

### Expected Console Output

When successful, you should see detailed logging:

```
=== Loading STEP File ===
  URL: /path/to/test.step
  File exists: true
  Calling OCCT bridge...
[STEPBridge] Reading STEP file: /path/to/test.step
[STEPBridge] Creating STEP reader...
[STEPBridge] Reading STEP file...
[STEPBridge] ✅ File read successfully
[STEPBridge] Found 1 root(s) for transfer
[STEPBridge] Transferring roots...
[STEPBridge] Transferred 1 shape(s)
[STEPBridge] Shape 1 type: 2
[STEPBridge] Extracting solids from shapes...
[STEPBridge]   Solid 0 has 6 face(s)
[STEPBridge] Extracted 1 solid(s) total
[STEPBridge] ✅ Parse complete, returning result
  ✅ STEP parsing succeeded via OCCT bridge
  JSON length: 2847 characters
  Parsing STEP result JSON...
  ✅ JSON parsed successfully
  Found 1 solid(s) in STEP file
  Processing solid 1/1...
    ✅ Classified as HSS-Rect
  ✅ Created model with 1 mesh(es)
✅ Success! Loaded: test
   Meshes: 1
   Vertices: 144
   Faces: 48
   Profile: HSS-Rect
   Length: 100.0
```

## Part 5: Understanding the Architecture

### Three-Layer Design

```
┌─────────────────────────────────┐
│     Swift Layer                 │
│  (ModelLoader.swift)            │
│                                 │
│  - File loading                 │
│  - JSON parsing                 │
│  - Model3D creation             │
└────────────┬────────────────────┘
             │
             │ Bridging Header
             │
┌────────────▼────────────────────┐
│  Pure Objective-C Layer         │
│  (STEPBridgeWrapper.m)          │
│                                 │
│  - Swift-compatible interface   │
│  - JSON serialization           │
└────────────┬────────────────────┘
             │
             │ Internal call
             │
┌────────────▼────────────────────┐
│  Objective-C++ Layer            │
│  (STEPBridge.mm)                │
│                                 │
│  - OpenCASCADE integration      │
│  - B-Rep extraction             │
│  - Geometry analysis            │
└────────────┬────────────────────┘
             │
             │ C++ calls
             │
┌────────────▼────────────────────┐
│  OpenCASCADE C++ Library        │
│  (TKDESTEP, TKBRep, etc.)       │
│                                 │
│  - STEP file parsing            │
│  - Geometry kernel              │
│  - Topology operations          │
└─────────────────────────────────┘
```

### Why This Architecture?

1. **Swift cannot directly call C++**
   - Need Objective-C or Objective-C++ as bridge

2. **Objective-C++ files (.mm) cannot be in bridging header**
   - Need pure Objective-C wrapper (.m)

3. **JSON as data format**
   - Simple, inspectable, debuggable
   - Easy to extend
   - Can be cached/saved

## Part 6: OpenCASCADE Version Compatibility

### Version 7.8.0+ (Current - RECOMMENDED)

**Release Date**: June 2023

**Major Changes**:
- Data Exchange module refactored
- `TKSTEP`, `TKSTEP209`, `TKSTEPBase`, `TKSTEPAttr` → `TKDESTEP`
- `TKIGES` → `TKDEIGES`
- Improved performance and maintainability

**Linker Flags**:
```
-lTKDESTEP -lTKXSBase
```

**Check if you have this version**:
```bash
brew list --versions opencascade
# Should show 7.8.0 or later
```

### Version 7.7.x and Earlier (Legacy)

**Status**: Deprecated architecture

**Linker Flags**:
```
-lTKSTEP -lTKSTEP209 -lTKSTEPBase -lTKSTEPAttr -lTKXSBase
```

**Migration Path**:
```bash
# Upgrade OCCT
brew upgrade opencascade

# Update linker flags in Xcode
# Remove: -lTKSTEP -lTKSTEP209 -lTKSTEPBase -lTKSTEPAttr
# Add: -lTKDESTEP

# Clean and rebuild
```

## Part 7: Troubleshooting

### Build Issues

See **QUICKFIX.md** for a comprehensive list of common errors and fixes.

Quick diagnostics:
```bash
# Check installation
./verify_occt.sh

# Check version
brew list --versions opencascade

# Check libraries
ls /opt/homebrew/opt/opencascade/lib/ | grep STEP

# Should show: libTKDESTEP.7.9.dylib (or similar)
```

### Runtime Issues

**App crashes on launch**:
- OCCT dylibs not found at runtime
- Solution: Copy dylibs to app bundle or fix @rpath

**STEP file loads slowly**:
- Normal for complex files
- Consider background parsing with progress UI

**"No solids found" error**:
- STEP file may contain only surfaces/curves
- Try a different STEP file

## Part 8: Next Steps

### Optional Enhancements

1. **Progress Reporting**:
   - Parse large files in background
   - Show progress UI

2. **Caching**:
   - Cache parsed results
   - Speed up repeated loads

3. **Error Recovery**:
   - Better handling of invalid files
   - Detailed error messages to user

4. **Extended Format Support**:
   - Add STL loader
   - Add IGES loader (use `TKDEIGES`)

### Further Reading

- OpenCASCADE Documentation: https://dev.opencascade.org/
- STEP Format Specification: ISO 10303-21
- OCCT Release Notes (7.8.0): https://dev.opencascade.org/doc/overview/html/occt_dev_guides__upgrade.html

## Summary

You now have a fully configured OpenCASCADE integration:

✅ OCCT 7.9.3 installed via Homebrew  
✅ Xcode project configured with correct paths and linker flags  
✅ Three-layer architecture (Swift → Obj-C → Obj-C++ → C++)  
✅ Comprehensive error logging  
✅ Support for compound shapes and complex geometry  
✅ Modern OCCT 7.8+ library names (TKDESTEP)  

Your app can now parse STEP files and extract B-Rep geometry!

---

**Last Updated**: March 19, 2026  
**OCCT Version**: 7.9.3  
**Status**: Production Ready  
**Platform**: macOS 13.0+
