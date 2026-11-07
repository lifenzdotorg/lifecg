# Vendored Syphon (Command Line Tools build)

This is a vendored copy of the **Syphon Framework**, set up to build with only the Command Line
Tools (no Xcode, no `xcodebuild`, no `metal` shader compiler).

- Upstream: https://github.com/Syphon/Syphon-Framework
- Pinned commit: `f4761677a45b8034a3c2069ec0f3d2553da81fba` (2026-09-21, `git describe`: `5-109-gf476167`,
  "Small fix so setting a SyphonServer.name correctly copies the new name…, Fixes #106")
- Licence: BSD 2-Clause, © 2010-2023 bangnoise (Tom Butterworth), vade (Anton Marini) and contributors
  (Metal parts © Maxime Touroute & Philippe Chaurand). The upstream licence is in `LICENSE`
  (upstream `License.txt`), and every source file keeps its original header. Redistributing a
  binary requires reproducing the licence text, for example in the app's About box or credits file.

## Layout

```
Package.swift                     SwiftPM manifest (library product "Syphon" + SyphonSmokeTest)
build.sh                          Builds without SwiftPM: clang -> libSyphon.a + include/ (module map)
Sources/Syphon/*.m|*.c|*.h        Upstream sources and private headers (unchanged except as listed below)
Sources/Syphon/Syphon_Prefix.h    Upstream Syphon_Prefix.pch, renamed and force-included with -include
Sources/Syphon/SyphonMetalShaders.metal   Upstream shader, kept for reference only (excluded from the build)
Sources/Syphon/include/Syphon/    Upstream public headers (Syphon.h umbrella, Metal and OpenGL server/client, directory)
Sources/Syphon/include/module.modulemap   `module Syphon` (replaces upstream's framework modulemap)
Sources/SyphonSmokeTest/main.swift        Round-trip test: publish, discover, read back, verify pixels and alpha
```

Upstream files that are not used: the Xcode project, Info.plist, docc, icon and Read Me.rtf.

## Patches to upstream

1. **`SyphonServerRendererMetal.m`: shaders are compiled at runtime.** Upstream calls
   `-[MTLDevice newDefaultLibraryWithBundle:]` to load a `default.metallib` built by Xcode. If that
   library is missing, the pipeline state can't be created, the renderer returns nil, and
   **`SyphonMetalServer` init returns nil**, so the Metal server really does need the shaders. The
   patch embeds the source of `SyphonMetalShaders.metal`, with the types from `SyphonServerMetalTypes.h`
   inlined, as a string. It compiles that string with `-[MTLDevice newLibraryWithSource:options:error:]`
   and caches the library per device (`NSMapTable` behind an `os_unfair_lock`). If compilation fails,
   it logs the error with NSLog and returns nil. All patched code is marked `VENDOR PATCH`. If you
   update upstream, keep the embedded string in sync with `SyphonMetalShaders.metal`.
   The shaders are only used when `flipped:` is YES or the source isn't `.bgra8Unorm`. An unflipped
   BGRA texture uses a blit.
2. **`Syphon_Prefix.pch` renamed to `Syphon_Prefix.h`** (content unchanged). It's passed with
   `-include`, the way Xcode's prefix header setting used it.
3. **New `include/module.modulemap`.** Upstream ships a `framework module`, which can't be used from a
   plain include directory.

The C and Objective-C sources are otherwise untouched. Compiler settings match upstream's Release
configuration: ARC, `SYPHON_CORE_SHARE`, plus `GL_SILENCE_DEPRECATION`.

**Class-name prefix:** upstream has no `SYPHON_UNIQUE_CLASS_NAME_PREFIX` (or similar) mechanism, so the
classes keep their upstream names. A clash can only happen if a second copy of Syphon is loaded into
the *same process* (for example a plugin bundling Syphon.framework). It can't happen across processes,
so it doesn't affect ProPresenter. Adding a prefix would mean renaming every class, which would also
change the Swift names, so it was left out.

## Building

### A. `build.sh` (no SwiftPM needed)

```
./build.sh <outdir>            # -> <outdir>/libSyphon.a (arm64 + x86_64), <outdir>/include/
./build.sh <outdir> --smoke    # also builds and runs <outdir>/SyphonSmokeTest
ARCHS=arm64 CONFIG=debug ./build.sh <outdir>   # debug build also enables upstream SYPHONLOG output
```

Compile your app against it:

```
swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -I <outdir>/include -L <outdir> -lSyphon \
  -framework Foundation -framework Cocoa -framework Metal -framework IOSurface \
  -framework OpenGL -framework CoreVideo \
  <your sources> -o <binary>
```

### B. SwiftPM: `.package(path: "Vendor/Syphon")`, product `Syphon`

`Package.swift` uses tools-version 6.0, macOS 13, and links Foundation, Cocoa, Metal, IOSurface,
OpenGL and CoreVideo. It uses `unsafeFlags(["-include", <prefix header>])`, which SwiftPM accepts for
root and local (path) dependencies.

**Known CLT problem on this machine:** every manifest fails to link with
`Undefined symbols … PackageDescription.Package.__allocating_init(… swiftLanguageVersions: …)`.
The cause is four stale files left over from a Feb 2024 CLT install:
`/Library/Developer/CommandLineTools/usr/lib/swift/pm/{ManifestAPI/PackageDescription,PluginAPI/PackagePlugin}.swiftmodule/*.private.swiftinterface`.
The compiler reads these in preference to the current `.swiftinterface`, and they don't match the
current `libPackageDescription.dylib`. To fix it permanently, delete those four files
(`sudo rm …/*.private.swiftinterface`) or reinstall the Command Line Tools. To work around it without
admin rights, point SwiftPM at a copy of the ManifestAPI directory that leaves those files out:

```
L=$HOME/.swiftpm-libs-fix; P=/Library/Developer/CommandLineTools/usr/lib/swift/pm
mkdir -p $L/ManifestAPI/PackageDescription.swiftmodule
ln -sf $P/ManifestAPI/libPackageDescription.dylib $P/ManifestAPI/CompilerPluginSupport.swiftmodule $L/ManifestAPI/
ln -sf $P/ManifestAPI/PackageDescription.swiftmodule/*-apple-macos.swift{interface,doc} $L/ManifestAPI/PackageDescription.swiftmodule/
ln -sfn $P/PluginAPI $L/PluginAPI
SWIFTPM_CUSTOM_LIBS_DIR=$L swift run SyphonSmokeTest
```

## Smoke test

`SyphonSmokeTest` creates a 1920×1080 premultiplied-alpha pattern with alpha values
{255, 191, 128, 64, 1, 0}. It publishes the pattern with `SyphonMetalServer` ("SmokeTest"), finds it
through `SyphonServerDirectory` while pumping the main run loop, connects a `SyphonMetalClient`, and
compares every byte of the client's IOSurface against the pattern. It runs three cases: the blit path,
the runtime-shader path with `flipped: true`, and the runtime-shader path with an `.rgba8Unorm` source.
Last result (M3 Pro, macOS 26.7): all 2,073,600 pixels match exactly in all three cases, and the test
prints `PASS`, with both build.sh and SwiftPM.
