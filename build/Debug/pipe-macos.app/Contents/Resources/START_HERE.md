# 🚀 START HERE - OpenCASCADE Integration

Everything is fixed and ready to go! Follow these steps to get your STEP parser working.

## The Problem

Your code was trying to use OpenCASCADE but had several issues:
- ❌ Wrong library names (using OCCT 7.7 names with OCCT 7.9)
- ❌ Missing bridging header
- ❌ Incomplete OCCT integration
- ❌ Poor error handling

## The Solution

All fixed! Here's what changed:

### ✅ Library Names Updated for OCCT 7.8+

**Old (broken)**:
```
-lTKSTEP -lTKSTEP209 -lTKSTEPBase -lTKSTEPAttr
```

**New (works with 7.9.3)**:
```
-lTKDESTEP
```

Why? OpenCASCADE 7.8.0 (June 2023) refactored the Data Exchange module and consolidated the 4 fragmented STEP libraries into one modern `TKDESTEP` library.

### ✅ Proper Swift-to-C++ Bridge

Created a three-layer architecture:
1. **Swift** (ModelLoader.swift) → 
2. **Objective-C** (STEPBridgeWrapper.m) → 
3. **Objective-C++** (STEPBridge.mm) → 
4. **C++** (OpenCASCADE)

### ✅ Files Ready to Use

All necessary files have been created/fixed:
- `OpenCASCADE.xcconfig` - Build configuration
- `pipe-macos-Bridging-Header.h` - Swift bridge
- `verify_occt.sh` - Installation checker
- `ModelLoader.swift` - Updated with proper bridge
- `STEPBridge.mm` - Fixed OCCT integration
- Documentation files (SETUP_GUIDE.md, QUICKFIX.md, etc.)

## Quick Start (5 Minutes)

### Step 1: Verify Installation

```bash
chmod +x verify_occt.sh
./verify_occt.sh
```

Expected output:
```
✅ OpenCASCADE is installed via Homebrew
   Version: 7.9.3
✅ TKDESTEP
✅ All checks passed!
```

If you see errors, follow the script's suggestions.

### Step 2: Configure Xcode

**Option A: Use xcconfig (Easiest)**
1. Add `OpenCASCADE.xcconfig` to your project (don't add to target)
2. Project → Info → Configurations → select "OpenCASCADE" for Debug/Release

**Option B: Manual Setup**
1. Build Settings → Header Search Paths: `/opt/homebrew/opt/opencascade/include/opencascade`
2. Build Settings → Library Search Paths: `/opt/homebrew/opt/opencascade/lib`
3. Build Settings → Other Linker Flags: `-lTKernel -lTKMath -lTKBRep -lTKGeomBase -lTKGeomAlgo -lTKTopAlgo -lTKPrim -lTKG3d -lTKG2d -lTKDESTEP -lTKXSBase`
4. Build Settings → Bridging Header: `$(PROJECT_DIR)/pipe-macos-Bridging-Header.h`
5. Build Settings → C++ Language Dialect: `GNU++17`

### Step 3: Add Files to Target

Make sure these are checked in File Inspector → Target Membership:
- ✅ STEPBridge.h
- ✅ STEPBridge.mm
- ✅ STEPBridgeWrapper.h
- ✅ STEPBridgeWrapper.m
- ✅ ModelLoader.swift
- ❌ pipe-macos-Bridging-Header.h (NO - referenced by build settings)

### Step 4: Build

```
Product → Clean Build Folder (Cmd+Shift+K)
Product → Build (Cmd+B)
```

Should build without errors!

### Step 5: Test

```swift
let url = URL(fileURLWithPath: "/path/to/test.step")
do {
    let model = try ModelLoader.load(url: url)
    print("✅ Loaded: \(model.name)")
    print("   Meshes: \(model.meshes.count)")
    print("   Profile: \(model.stockInfo?.profile.rawValue ?? "unknown")")
} catch {
    print("❌ Error: \(error)")
}
```

## Expected Console Output

When working, you'll see:
```
=== Loading STEP File ===
  URL: /path/to/test.step
  File exists: true
  Calling OCCT bridge...
[STEPBridge] Reading STEP file: /path/to/test.step
[STEPBridge] ✅ File read successfully
[STEPBridge] Found 1 root(s) for transfer
[STEPBridge] Transferring roots...
[STEPBridge] Transferred 1 shape(s)
[STEPBridge] Extracted 1 solid(s) total
[STEPBridge] ✅ Parse complete
  ✅ STEP parsing succeeded via OCCT bridge
  ✅ JSON parsed successfully
  Found 1 solid(s) in STEP file
    ✅ Classified as HSS-Rect
  ✅ Created model with 1 mesh(es)
```

## Common Issues

### "Cannot find 'STEPBridgeWrapper' in scope"
**Fix**: Check bridging header path in Build Settings

### "Library not found for -lTKSTEP"
**Fix**: You're using old library names. Update to `-lTKDESTEP`

### "Library not found for -lTKDESTEP"  
**Fix**: Your OCCT is too old. Run `brew upgrade opencascade`

### Other Issues?
See **QUICKFIX.md** for comprehensive troubleshooting

## Documentation Files

- **START_HERE.md** (this file) - Quick start guide
- **SETUP_GUIDE.md** - Complete setup walkthrough
- **QUICKFIX.md** - Common errors and solutions
- **FIXES_SUMMARY.md** - What was changed and why
- **BuildSettings.txt** - Build configuration reference

## What Makes OCCT 7.8+ Different?

### The Old Way (≤ 7.7.0)
```
TKSTEP          ← Basic STEP support
TKSTEP209       ← STEP AP209 support
TKSTEPBase      ← STEP base classes
TKSTEPAttr      ← STEP attributes
```
4 separate libraries, fragmented architecture

### The New Way (≥ 7.8.0)
```
TKDESTEP        ← All STEP functionality
```
1 modern, consolidated library

**Benefits**:
- Faster linking
- Better maintenance
- Cleaner architecture
- Smaller binary size

## Architecture Overview

```
┌────────────────┐
│     Swift      │  ModelLoader.swift
│                │  - Load STEP files
│                │  - Parse JSON results
└───────┬────────┘
        │ via bridging header
        │
┌───────▼────────┐
│  Objective-C   │  STEPBridgeWrapper.m
│                │  - Pure Obj-C wrapper
│                │  - JSON conversion
└───────┬────────┘
        │ internal call
        │
┌───────▼────────┐
│ Objective-C++  │  STEPBridge.mm
│                │  - OCCT integration
│                │  - B-Rep extraction
└───────┬────────┘
        │ C++ calls
        │
┌───────▼────────┐
│ OpenCASCADE    │  TKDESTEP + other libs
│   C++ Library  │  - STEP parsing
│                │  - Geometry kernel
└────────────────┘
```

## Key Files Explained

| File | Purpose | Language |
|------|---------|----------|
| ModelLoader.swift | Main API | Swift |
| pipe-macos-Bridging-Header.h | Expose Obj-C to Swift | C header |
| STEPBridgeWrapper.h/m | Pure Obj-C wrapper | Objective-C |
| STEPBridge.h/mm | OCCT integration | Objective-C++ |
| OpenCASCADE.xcconfig | Build config | Xcode config |

## Success Checklist

- [ ] OpenCASCADE 7.8+ installed (`brew list --versions opencascade`)
- [ ] Verification script passes (`./verify_occt.sh`)
- [ ] Xcode configured (xcconfig or manual)
- [ ] All files added to target (except bridging header)
- [ ] Build succeeds without errors
- [ ] Test STEP file loads successfully
- [ ] Console shows detailed logging

## Need Help?

1. Run `./verify_occt.sh` for diagnostics
2. Check **QUICKFIX.md** for your specific error
3. Review **SETUP_GUIDE.md** for detailed setup
4. Look at console output for specific error messages

## What's Next?

Once basic loading works, consider:

1. **Performance**: Background parsing for large files
2. **UI**: Progress indicators during load
3. **Caching**: Save parsed results
4. **Features**: Add STL/IGES support
5. **Error Handling**: User-friendly error messages

## Summary

✅ All code updated for OCCT 7.9.3  
✅ Modern library names (TKDESTEP)  
✅ Proper Swift-to-C++ bridge  
✅ Comprehensive error logging  
✅ Complete documentation  

**You're ready to parse STEP files!** 🎉

---

**Questions?** Check the documentation files or review console output for clues.
