[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtDirectory,
    [Parameter(Mandatory)][string]$VcpkgDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$JomPath,
    [string]$PkgConfigPath,
    [string]$PerlPath = 'C:/Strawberry/perl/bin/perl.exe',
    [ValidateRange(1, 32)][int]$Jobs = 6
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$QtDirectory = (Resolve-Path -LiteralPath $QtDirectory).Path
$VcpkgDirectory = (Resolve-Path -LiteralPath $VcpkgDirectory).Path
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$qtBin = Join-Path $QtDirectory 'bin'

function Invoke-BuildCommand {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Program $($Arguments -join ' ')"
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) {
    throw 'Install Visual Studio 2022 Build Tools with the C++ workload first.'
}
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$visualStudio) {
    throw 'No complete Visual Studio C++ installation found.'
}
$devCommand = Join-Path $visualStudio 'Common7/Tools/VsDevCmd.bat'
$devEnvironment = & cmd.exe /d /s /c "call `"$devCommand`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the MSVC environment.' }
foreach ($entry in $devEnvironment) {
    $separator = $entry.IndexOf('=')
    if ($separator -gt 0) {
        [Environment]::SetEnvironmentVariable($entry.Substring(0, $separator), $entry.Substring($separator + 1), 'Process')
    }
}
$env:PATH = "$qtBin;$env:PATH"
$env:VCPKG_ROOT = $VcpkgDirectory
$env:VCPKG_DISABLE_METRICS = '1'
if ($PkgConfigPath) {
    $env:PKG_CONFIG = (Resolve-Path -LiteralPath $PkgConfigPath).Path
    $env:VCPKG_KEEP_ENV_VARS = 'PKG_CONFIG'
}

# Use a complete native Windows Perl. MSYS Perl generates incompatible paths,
# and some other Windows utilities bundle a Perl without the required modules.
$perlExecutable = (Resolve-Path -LiteralPath $PerlPath).Path
$shimDirectory = Join-Path $BuildDirectory 'tool-shims'
New-Item -ItemType Directory -Path $shimDirectory -Force | Out-Null
$perlShim = Join-Path $shimDirectory 'perl.cmd'
[IO.File]::WriteAllText($perlShim, '@"' + $perlExecutable + '" %*' + [Environment]::NewLine, [Text.Encoding]::ASCII)
$env:PATH = "$shimDirectory;$env:PATH"
$env:LC_ALL = 'C'

$qmake = Join-Path $qtBin 'qmake.exe'
if (!(Test-Path -LiteralPath $qmake)) { throw "qmake.exe not found in $qtBin" }
$make = 'nmake.exe'
$makeArguments = @('/NOLOGO')
if ($JomPath) {
    $make = (Resolve-Path -LiteralPath $JomPath).Path
    $makeArguments = @('-j', "$Jobs")
}
New-Item -ItemType Directory -Path $BuildDirectory, $OutputDirectory -Force | Out-Null

Push-Location $repositoryRoot
try {
    Write-Host '[1/6] Preparing source dependencies'
    Invoke-BuildCommand 'git' @('submodule', 'update', '--init', '--depth', '1', 'src/smtpclient', 'src/qthttpserver')
    Copy-Item -Path 'qHttpServerBin/5.15.2/headers/*' -Destination 'src/qthttpserver/src/3rdparty/http-parser/' -Force

    Write-Host '[2/6] Building protobuf and abseil'
    Invoke-BuildCommand (Join-Path $VcpkgDirectory 'vcpkg.exe') @('install', 'protobuf:x64-windows', 'protobuf-c:x64-windows', 'abseil:x64-windows', '--disable-metrics')
    $dependencyRoot = Join-Path $VcpkgDirectory 'installed/x64-windows'

    Write-Host '[3/6] Building and installing QtHttpServer'
    $httpBuild = Join-Path $BuildDirectory 'qthttpserver'
    if (!(Test-Path -LiteralPath (Join-Path $QtDirectory 'lib/Qt5HttpServer.lib'))) {
        New-Item -ItemType Directory -Path $httpBuild -Force | Out-Null
        Push-Location $httpBuild
        try {
            Invoke-BuildCommand $qmake @('-r', (Join-Path $repositoryRoot 'src/qthttpserver/qthttpserver.pro'), '-after', 'CONFIG-=debug', 'CONFIG-=debug_and_release', 'CONFIG+=release')
            Invoke-BuildCommand $make $makeArguments
            Invoke-BuildCommand $make ($makeArguments + @('install'))
        } finally { Pop-Location }
    }

    Write-Host '[4/6] Compiling QZ for Windows x64'
    $translationsNeedUpdate = $false
    foreach ($translation in Get-ChildItem -Path 'src/translations/*.ts') {
        $compiledTranslation = [IO.Path]::ChangeExtension($translation.FullName, '.qm')
        if (!(Test-Path -LiteralPath $compiledTranslation) -or
            (Get-Item -LiteralPath $compiledTranslation).LastWriteTimeUtc -lt $translation.LastWriteTimeUtc) {
            $translationsNeedUpdate = $true
            break
        }
    }
    if ($translationsNeedUpdate) {
        Invoke-BuildCommand (Join-Path $qtBin 'lrelease.exe') @('src/qdomyos-zwift.pri')
    }
    $appBuild = Join-Path $BuildDirectory 'app'
    New-Item -ItemType Directory -Path $appBuild -Force | Out-Null
    Push-Location $appBuild
    try {
        $includePath = (Join-Path $dependencyRoot 'include').Replace('\', '/')
        $libraryPath = (Join-Path $dependencyRoot 'lib').Replace('\', '/')
        Invoke-BuildCommand $qmake @((Join-Path $repositoryRoot 'src/qdomyos-zwift.pro'), "INCLUDEPATH+=$includePath", "LIBS+=-L$libraryPath", '-after', 'CONFIG-=debug', 'CONFIG-=debug_and_release', 'CONFIG+=release')
        Invoke-BuildCommand $make $makeArguments
    } finally { Pop-Location }

    Write-Host '[5/6] Packaging the executable and runtime libraries'
    # The repository's prebuilt release Bluetooth DLL is invalid. Rebuild the
    # same Qt version with the project's source patches instead of shipping it.
    Write-Host 'Building patched QtBluetooth from source'
    $runtimeDirectory = Join-Path $BuildDirectory 'runtime'
    $bluetoothSource = Join-Path $runtimeDirectory 'qtconnectivity-everywhere-src-5.15.2'
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    if (!(Test-Path -LiteralPath (Join-Path $bluetoothSource 'qtconnectivity.pro'))) {
        $sourceArchive = Join-Path $runtimeDirectory 'qtconnectivity-5.15.2.tar.xz'
        Invoke-WebRequest 'https://download.qt.io/archive/qt/5.15/5.15.2/submodules/qtconnectivity-everywhere-src-5.15.2.tar.xz' -OutFile $sourceArchive
        $sourceHash = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash
        if ($sourceHash -ne '0380327871f76103e5b8c2a305988d76d352b6a982b3e7b3bc3cdc184c64bfa0') {
            throw 'QtConnectivity source checksum mismatch.'
        }
        Invoke-BuildCommand 'tar.exe' @('-xf', $sourceArchive, '-C', $runtimeDirectory)
    }
    foreach ($patch in Get-ChildItem -Path 'qt-patches/windows/5.15.2/*.cpp') {
        $destination = Join-Path $bluetoothSource "src/bluetooth/$($patch.Name)"
        if ((Get-FileHash -LiteralPath $patch.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
            Copy-Item -LiteralPath $patch.FullName -Destination $destination -Force
        }
    }
    $bluetoothBuild = Join-Path $runtimeDirectory 'bluetooth-build'
    New-Item -ItemType Directory -Path $bluetoothBuild -Force | Out-Null
    Push-Location $bluetoothBuild
    try {
        Invoke-BuildCommand $qmake @('-r', (Join-Path $bluetoothSource 'qtconnectivity.pro'), '-after', 'CONFIG-=debug', 'CONFIG-=debug_and_release', 'CONFIG+=release')
        Invoke-BuildCommand $make $makeArguments
    } finally { Pop-Location }

    $application = Join-Path $appBuild 'qdomyos-zwift.exe'
    if (!(Test-Path -LiteralPath $application)) { throw "Missing output executable: $application" }
    Copy-Item -LiteralPath $application -Destination $OutputDirectory -Force
    $packagedApplication = Join-Path $OutputDirectory 'qdomyos-zwift.exe'
    Invoke-BuildCommand (Join-Path $qtBin 'windeployqt.exe') @('--release', '--compiler-runtime', '--qmldir', (Join-Path $repositoryRoot 'src'), $packagedApplication)
    if ($env:VCToolsRedistDir) {
        $crtLibraries = Join-Path $env:VCToolsRedistDir 'x64/Microsoft.VC143.CRT/*.dll'
        if (Test-Path -Path $crtLibraries) {
            Copy-Item -Path $crtLibraries -Destination $OutputDirectory -Force
        }
    }
    Copy-Item -Path (Join-Path $dependencyRoot 'bin/*.dll') -Destination $OutputDirectory -Force
    Copy-Item -Path 'windows_openssl/*.dll' -Destination $OutputDirectory -Force
    Copy-Item -LiteralPath (Join-Path $bluetoothBuild 'lib/Qt5Bluetooth.dll') -Destination $OutputDirectory -Force
    Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $OutputDirectory 'LICENSE.txt') -Force
    $adbDirectory = Join-Path $OutputDirectory 'adb'
    New-Item -ItemType Directory -Path $adbDirectory -Force | Out-Null
    Copy-Item -Path 'src/adb/*' -Destination $adbDirectory -Force
    $sourceCommit = & git rev-parse HEAD
    @(
        'QZ Windows x64 - local Release build',
        "Source commit: $sourceCommit",
        "Built (UTC): $([DateTime]::UtcNow.ToString('o'))",
        'Windows timed trial and supporter lookup disabled in this fork.',
        'Keep this directory together and run qdomyos-zwift.exe.',
        'Optional Python/PaddleOCR runtime is not included.'
    ) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'BUILD-INFO.txt') -Encoding utf8

    Write-Host '[6/6] Verifying the packaged application'
    $previousPath = $env:PATH
    $previousPlatform = $env:QT_QPA_PLATFORM
    try {
        $env:PATH = "$env:SystemRoot/System32;$env:SystemRoot"
        $env:QT_QPA_PLATFORM = 'offscreen'
        $smokeOutput = & $packagedApplication -smoke-test
        if ($LASTEXITCODE -ne 0 -or $smokeOutput -notcontains 'SMOKE_OK') {
            throw 'The packaged application failed its startup check.'
        }
        Write-Host 'SMOKE_OK'
    } finally {
        $env:PATH = $previousPath
        $env:QT_QPA_PLATFORM = $previousPlatform
    }
    Write-Host 'Build complete'
    Write-Host $packagedApplication
    Write-Host 'This package does not include the optional Python/PaddleOCR runtime.'
} finally { Pop-Location }
