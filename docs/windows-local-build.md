# Local Windows x64 build

The `windows-no-trial` branch disables the timed trial and supporter lookup on
Windows. The change is limited to the Windows startup path in `homeform.cpp`.

## Toolchain

Use the following tools:

- Visual Studio 2022 Build Tools with the C++ workload and Windows SDK.
- Qt 5.15.2 for `win64_msvc2019_64`, including `qtcharts` and `qtnetworkauth`.
- A complete native Windows Perl, such as Strawberry Perl. Git's MSYS Perl
  generates incompatible forwarding-header paths for QtHttpServer.
- Git for Windows.
- vcpkg at commit `8c2fcacefba009d63672f9d137f192765e632c9f` (the same port
  baseline used by the upstream Windows workflow), bootstrapped with
  `bootstrap-vcpkg.bat -disableMetrics`.
- Optional: Qt's `jom` to compile several files at once; otherwise the script
  uses `nmake`.

Qt can be installed without the graphical Qt installer:

```powershell
python -m venv build-env
./build-env/Scripts/python.exe -m pip install aqtinstall==3.3.0
./build-env/Scripts/python.exe -m aqt install-qt windows desktop 5.15.2 win64_msvc2019_64 --outputdir ./qt --modules qtcharts qtnetworkauth
```

Install the Microsoft and Perl tools with:

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
winget install --id StrawberryPerl.StrawberryPerl --exact
```

## pkg-config with the pinned vcpkg baseline

This old vcpkg version downloads an MSYS runtime package which is no longer
available from its original mirrors. Supply a standalone native `pkg-config.exe`
using `-PkgConfigPath` to avoid that download. The MSYS2 package
`mingw-w64-x86_64-pkgconf-1~2.3.0-1-any.pkg.tar.zst` contains native Windows
executables in `mingw64/bin`. Keep `libpkgconf-5.dll` beside the executable.

The original vcpkg download declaration specifies this SHA-512 checksum:

```text
5373f050060678166968e09a4dd8ad30324c5dc37842c3517ebc9eb7be7e09d37d2873ff9dc4831c283556b68a0776f06fa6f91d799020b04282b4a3f378a2c4
```

## Build and package

From the repository root, run PowerShell with the paths to the installed tools:

```powershell
./tools/build_windows.ps1 `
  -QtDirectory C:/QZ/qt/5.15.2/msvc2019_64 `
  -VcpkgDirectory C:/QZ/vcpkg `
  -BuildDirectory C:/QZ/build `
  -OutputDirectory C:/QZ/package `
  -JomPath C:/QZ/jom/jom.exe `
  -PerlPath C:/QZ/strawberry/perl/bin/perl.exe `
  -PkgConfigPath C:/QZ/pkgconf/mingw64/bin/pkg-config.exe
```

The script initializes the MSVC x64 environment, prepares the required
submodules, builds protobuf/abseil and QtHttpServer, compiles QZ in Release mode,
and deploys the Qt libraries, OpenSSL DLLs, the patched Bluetooth module, and ADB.
Build files stay in `BuildDirectory`; generated translation files are ignored
by Git.

The tracked prebuilt Release Bluetooth DLL is not a valid Windows binary. The
script downloads the official QtConnectivity 5.15.2 source archive, verifies its
SHA-256 checksum, applies the three source files from `qt-patches/windows/5.15.2`,
and builds a matching Release DLL locally. This also avoids mixing the older
prebuilt DLL's debug Qt dependencies with the Release application.

Run `qdomyos-zwift.exe` from `OutputDirectory`. Keep the whole package directory
together. This build does not include the optional Python/PaddleOCR runtime.
Service integrations that require upstream API credentials need their own keys;
the build does not supply the upstream project's private credentials.
