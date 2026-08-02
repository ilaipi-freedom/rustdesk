$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\")).Path
$buildRoot = Join-Path $repo ".gitea-build"
$stage = Join-Path $buildRoot "stage"
$portable = Join-Path $stage "rustdesk-windows-x64-portable"
$packerRoot = Join-Path $buildRoot "portable-packer"
$destination = "D:\work\YYM\release\jwvisdesk"

$flutterVersion = "3.24.5"
$rustVersion = "1.75"
$llvmVersion = "15.0.6"
$cargoExpandVersion = "1.0.95"
$bridgeVersion = "1.80.1"
$nugetUri = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
$defaultToolCacheRoot = "C:\ProgramData\jwvisdesk-cache"
# Keep the source registry at schema 2 for the pinned vcpkg tool and VS2026 support.
$vcpkgCommit = "78f1a9e06a9a01f1b7b67e87c91600627ec66872"
$vcpkgToolVersion = "2026-07-27"
$vcpkgToolUri = "https://github.com/microsoft/vcpkg-tool/releases/download/$vcpkgToolVersion/vcpkg.exe"
$vcpkgNasmVersion = "2.16.03"
$vcpkgNasmSha512 = "22869ceb70ea0e6597fe06abe205b5d5dd66b41fe54dda73d338c488ba6ef13a39158f25b357616bf578752bb112869ef26ad897eb29352e85cf1ecc61a7c07a"
$vcpkgTriplet = "x64-windows-static"
$rustTarget = "x86_64-pc-windows-msvc"
$rustupUri = "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
$flutterUri = "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_${flutterVersion}-stable.zip"

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Add-PathEntry {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        return
    }
    $entries = @($env:Path -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries -notcontains $Directory) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][object[]]$Arguments = @()
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    # Windows PowerShell turns native stderr (including harmless warnings) into
    # terminating errors when ErrorActionPreference is Stop. Preserve output and
    # rely on the process exit code for command failure instead.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Path
}

function Test-VcpkgToolVersion {
    param([Parameter(Mandatory = $true)][string]$Executable)

    if (-not (Test-Path -LiteralPath $Executable)) {
        return $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = (& $Executable "version" 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return $exitCode -eq 0 -and $output -match [regex]::Escape($vcpkgToolVersion)
}

function Update-VcpkgTool {
    param([Parameter(Mandatory = $true)][string]$Root)

    $target = Join-Path $Root "vcpkg.exe"
    $download = Join-Path $Root "vcpkg.exe.download"
    Download-File $vcpkgToolUri $download
    Move-Item -LiteralPath $download -Destination $target -Force
    if (-not (Test-VcpkgToolVersion $target)) {
        throw "vcpkg tool $vcpkgToolVersion was not installed at $target."
    }
    Write-Host "Using vcpkg tool $vcpkgToolVersion from $target."
}

function Initialize-RustToolchain {
    param([Parameter(Mandatory = $true)][string]$Root)

    $configuredCache = $env:RUSTDESK_TOOL_CACHE
    $cacheRoot = if ([string]::IsNullOrWhiteSpace($configuredCache)) {
        Join-Path $defaultToolCacheRoot "rust"
    } else {
        [Environment]::ExpandEnvironmentVariables($configuredCache)
    }
    $cacheRoot = [IO.Path]::GetFullPath($cacheRoot)
    $cargoHome = Join-Path $cacheRoot "cargo"
    $rustupHome = Join-Path $cacheRoot "rustup"
    $cargoBin = Join-Path $cargoHome "bin"
    $rustup = Join-Path $cargoBin "rustup.exe"
    $installer = Join-Path $cacheRoot "rustup-init.exe"

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $cargoHome -Force | Out-Null
    New-Item -ItemType Directory -Path $rustupHome -Force | Out-Null
    $env:CARGO_HOME = $cargoHome
    $env:RUSTUP_HOME = $rustupHome
    if ($env:Path -notlike "*$cargoBin*") {
        $env:Path = "$cargoBin;$env:Path"
    }

    if (-not (Test-Path -LiteralPath $rustup)) {
        if (-not (Test-Path -LiteralPath $installer)) {
            Download-File $rustupUri $installer
        }
        Invoke-Checked $installer @("--no-modify-path", "-y", "--default-toolchain", "none", "--profile", "minimal")
    }
    if (-not (Test-Path -LiteralPath $rustup)) {
        throw "rustup bootstrap did not create the expected executable: $rustup"
    }

    Invoke-Checked $rustup @("toolchain", "install", $rustVersion, "--profile", "minimal")
    Invoke-Checked $rustup @("target", "add", $rustTarget, "--toolchain", $rustVersion)
    Invoke-Checked $rustup @("component", "add", "rustfmt", "--toolchain", $rustVersion)
    Invoke-Checked "cargo" @("+$rustVersion", "--version")
    Write-Host "Using Rust $rustVersion from $cacheRoot."
}

function Remove-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Initialize-Flutter {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (Get-Command "flutter" -ErrorAction SilentlyContinue) {
        Write-Host "Using Flutter already available on PATH."
        return
    }

    $installedFlutterBins = @()
    if (-not [string]::IsNullOrWhiteSpace($env:RUSTDESK_FLUTTER_ROOT)) {
        $installedFlutterBins += Join-Path ([Environment]::ExpandEnvironmentVariables($env:RUSTDESK_FLUTTER_ROOT)) "bin"
    }
    $installedFlutterBins += @(
        "C:\ProgramData\jwzn\flutter\bin",
        "C:\ProgramData\jwvisdesk\flutter\bin",
        "C:\Flutter\bin",
        "C:\tools\flutter\bin"
    )
    foreach ($installedFlutterBin in ($installedFlutterBins | Select-Object -Unique)) {
        $installedFlutterCommand = Join-Path $installedFlutterBin "flutter.bat"
        if (Test-Path -LiteralPath $installedFlutterCommand) {
            Add-PathEntry $installedFlutterBin
            Write-Host "Using preinstalled Flutter from $installedFlutterBin."
            return
        }
    }

    $flutterCache = Join-Path $Root "tools\flutter"
    $flutterRoot = Join-Path $flutterCache "flutter"
    $flutterBin = Join-Path $flutterRoot "bin"
    $flutterCommand = Join-Path $flutterBin "flutter.bat"
    $archive = Join-Path $flutterCache "flutter-$flutterVersion-windows-x64.zip"
    $archiveCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:RUSTDESK_FLUTTER_ARCHIVE)) {
        $archiveCandidates += [Environment]::ExpandEnvironmentVariables($env:RUSTDESK_FLUTTER_ARCHIVE)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $archiveCandidates += Join-Path $env:USERPROFILE "Downloads\flutter_windows_${flutterVersion}-stable.zip"
    }
    $archiveCandidates += "C:\Users\Smark\Downloads\flutter_windows_${flutterVersion}-stable.zip"

    New-Item -ItemType Directory -Path $flutterCache -Force | Out-Null
    if (-not (Test-Path -LiteralPath $flutterCommand)) {
        if (-not (Test-Path -LiteralPath $archive)) {
            $localArchive = $archiveCandidates |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($localArchive)) {
                $archive = $localArchive
                Write-Host "Using local Flutter archive $archive."
            } else {
                Download-File $flutterUri $archive
            }
        }
        Remove-Directory $flutterRoot
        Expand-Archive -LiteralPath $archive -DestinationPath $flutterCache -Force
    }
    if (-not (Test-Path -LiteralPath $flutterCommand)) {
        throw "Flutter $flutterVersion was not installed at $flutterCommand."
    }

    if ($env:Path -notlike "*$flutterBin*") {
        $env:Path = "$flutterBin;$env:Path"
    }
    Write-Host "Using Flutter $flutterVersion from $flutterRoot."
}

function Initialize-Llvm {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (Get-Command "clang" -ErrorAction SilentlyContinue) {
        Write-Host "Using LLVM already available on PATH."
        return
    }

    $llvmBinCandidates = @(
        "C:\Program Files\LLVM\bin",
        "C:\Program Files (x86)\LLVM\bin"
    )
    if (-not [string]::IsNullOrWhiteSpace($env:LLVM_ROOT)) {
        $llvmBinCandidates += $env:LLVM_ROOT
        $llvmBinCandidates += Join-Path $env:LLVM_ROOT "bin"
    }
    $llvmBinCandidates += Get-ChildItem -Path "C:\Program Files\Microsoft Visual Studio\2022" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "VC\Tools\Llvm\x64\bin" }

    foreach ($llvmBin in ($llvmBinCandidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $llvmBin "clang.exe")) {
            if ($env:Path -notlike "*$llvmBin*") {
                $env:Path = "$llvmBin;$env:Path"
            }
            Write-Host "Using LLVM from $llvmBin."
            return
        }
    }

    throw "LLVM $llvmVersion was not found. Install it for all users or set LLVM_ROOT to its installation directory. Checked: $($llvmBinCandidates -join '; ')"
}

function Initialize-WindowsBuildTools {
    $toolDirectories = @(
        "C:\Program Files\CMake\bin",
        "C:\Program Files (x86)\CMake\bin"
    )
    $visualStudioRoots = @(
        (Join-Path $env:ProgramFiles "Microsoft Visual Studio"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    foreach ($visualStudioRoot in $visualStudioRoots) {
        Get-ChildItem -LiteralPath $visualStudioRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $toolDirectories += Join-Path $_.FullName "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
                        $toolDirectories += Join-Path $_.FullName "MSBuild\Current\Bin\amd64"
                        $toolDirectories += Join-Path $_.FullName "MSBuild\Current\Bin"
                    }
            }
    }

    foreach ($toolDirectory in ($toolDirectories | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath (Join-Path $toolDirectory "cmake.exe")) -or
            (Test-Path -LiteralPath (Join-Path $toolDirectory "ninja.exe")) -or
            (Test-Path -LiteralPath (Join-Path $toolDirectory "MSBuild.exe"))) {
            Add-PathEntry $toolDirectory
        }
    }

    if (Get-Command "ninja" -ErrorAction SilentlyContinue) {
        Write-Host "Using Ninja from $((Get-Command ninja).Source)."
    }
    if (Get-Command "msbuild" -ErrorAction SilentlyContinue) {
        Write-Host "Using MSBuild from $((Get-Command msbuild).Source)."
    }
}

function Initialize-NuGet {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (Get-Command "nuget" -ErrorAction SilentlyContinue) {
        Write-Host "Using NuGet already available on PATH."
        return
    }

    $nugetCache = Join-Path $Root "tools\nuget"
    $nugetPath = Join-Path $nugetCache "nuget.exe"
    New-Item -ItemType Directory -Path $nugetCache -Force | Out-Null

    $nugetCandidates = @(
        "C:\Program Files\NuGet\nuget.exe",
        "C:\Program Files (x86)\NuGet\nuget.exe",
        "C:\ProgramData\NuGet\nuget.exe"
    )
    if (-not [string]::IsNullOrWhiteSpace($env:RUSTDESK_NUGET_EXE)) {
        $nugetCandidates += [Environment]::ExpandEnvironmentVariables($env:RUSTDESK_NUGET_EXE)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $nugetCandidates += Join-Path $env:USERPROFILE "Downloads\nuget.exe"
    }
    $nugetCandidates += "C:\Users\Smark\Downloads\nuget.exe"

    if (-not (Test-Path -LiteralPath $nugetPath)) {
        $localNuGet = $nugetCandidates |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($localNuGet)) {
            Copy-Item -LiteralPath $localNuGet -Destination $nugetPath -Force
            Write-Host "Using local NuGet executable $localNuGet."
        } else {
            Download-File $nugetUri $nugetPath
        }
    }

    if (-not (Test-Path -LiteralPath $nugetPath)) {
        throw "NuGet executable was not installed at $nugetPath."
    }
    Add-PathEntry $nugetCache
    Write-Host "Using NuGet from $nugetPath."
}

function Get-VcpkgRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $configuredRoot = $env:VCPKG_ROOT
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and
        (Test-Path -LiteralPath (Join-Path $configuredRoot ".git")) -and
        (Test-Path -LiteralPath (Join-Path $configuredRoot "vcpkg.exe"))) {
        $current = (& git -C $configuredRoot rev-parse HEAD 2>$null | Out-String).Trim()
        $promisor = (& git -C $configuredRoot config --get remote.origin.promisor 2>$null | Out-String).Trim()
        if ($current -eq $vcpkgCommit -and $promisor -ne "true" -and
            (Test-VcpkgToolVersion (Join-Path $configuredRoot "vcpkg.exe"))) {
            Write-Host "Using configured vcpkg at $configuredRoot ($current)."
            return $configuredRoot
        }
        Write-Host "Configured vcpkg is incomplete, partial, outdated, or not at the required commit; using the persistent cache."
    }

    $localRoot = Join-Path $defaultToolCacheRoot "vcpkg"
    if (Test-Path -LiteralPath $localRoot) {
        $cachedGit = Join-Path $localRoot ".git"
        $cachedExe = Join-Path $localRoot "vcpkg.exe"
        $current = if (Test-Path -LiteralPath $cachedGit) {
            (& git -C $localRoot rev-parse HEAD 2>$null | Out-String).Trim()
        } else {
            ""
        }
        $promisor = if (Test-Path -LiteralPath $cachedGit) {
            (& git -C $localRoot config --get remote.origin.promisor 2>$null | Out-String).Trim()
        } else {
            ""
        }
        if ($current -eq $vcpkgCommit -and (Test-Path -LiteralPath $cachedExe) -and $promisor -ne "true") {
            if (Test-VcpkgToolVersion $cachedExe) {
                Write-Host "Using cached vcpkg at $localRoot ($current)."
                return $localRoot
            }
            Write-Host "Updating the cached vcpkg tool for Visual Studio 2026 compatibility."
            Update-VcpkgTool $localRoot
            return $localRoot
        }
        Write-Host "Cached vcpkg is incomplete, partial, outdated, or not at the required commit; rebuilding."
        Remove-Directory $localRoot
    }

    New-Item -ItemType Directory -Path $defaultToolCacheRoot -Force | Out-Null
    Invoke-Checked "git" @("clone", "--no-tags", "https://github.com/microsoft/vcpkg.git", $localRoot)
    Invoke-Checked "git" @("-C", $localRoot, "fetch", "--depth", "1", "origin", $vcpkgCommit)
    Invoke-Checked "git" @("-C", $localRoot, "checkout", "--force", $vcpkgCommit)
    Invoke-Checked (Join-Path $localRoot "bootstrap-vcpkg.bat") @("-disableMetrics")
    Update-VcpkgTool $localRoot
    return $localRoot
}

function Set-VcpkgNasmVersion {
    param([Parameter(Mandatory = $true)][string]$Root)

    # AOM checks for NASM's -Ox multipass optimization flag. NASM 3.01 no
    # longer exposes that flag, so use the last compatible vcpkg tool version.
    $finder = Join-Path $Root "scripts\cmake\vcpkg_find_acquire_program(NASM).cmake"
    if (-not (Test-Path -LiteralPath $finder)) {
        throw "vcpkg NASM acquisition file was not found at $finder."
    }

    $content = @'
set(program_name nasm)
set(program_version __NASM_VERSION__)
set(brew_package_name "nasm")
set(apt_package_name "nasm")
if(CMAKE_HOST_WIN32)
    set(download_urls
        "https://www.nasm.us/pub/nasm/releasebuilds/${program_version}/win64/nasm-${program_version}-win64.zip"
        "https://vcpkg.github.io/assets/nasm/nasm-${program_version}-win64.zip"
    )
    set(download_filename "nasm-${program_version}-win64.zip")
    set(download_sha512 __NASM_SHA512__)
    set(paths_to_search "${DOWNLOADS}/tools/nasm/nasm-${program_version}")
endif()
'@
    $content = $content.Replace("__NASM_VERSION__", $vcpkgNasmVersion).Replace("__NASM_SHA512__", $vcpkgNasmSha512)
    [IO.File]::WriteAllText($finder, $content, [Text.UTF8Encoding]::new($false))
    Write-Host "Configured vcpkg to use NASM $vcpkgNasmVersion for AOM compatibility."
}

function Replace-ByteSequence {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Data,
        [Parameter(Mandatory = $true)][byte[]]$Old,
        [Parameter(Mandatory = $true)][byte[]]$New
    )

    if ($Old.Length -ne $New.Length) {
        throw "Flutter snapshot replacement strings must have the same byte length."
    }
    for ($i = 0; $i -le $Data.Length - $Old.Length; $i++) {
        $matches = $true
        for ($j = 0; $j -lt $Old.Length; $j++) {
            if ($Data[$i + $j] -ne $Old[$j]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            for ($j = 0; $j -lt $New.Length; $j++) {
                $Data[$i + $j] = $New[$j]
            }
            return $true
        }
    }
    return $false
}

function Patch-FlutterVisualStudioGenerator {
    param([Parameter(Mandatory = $true)][string]$FlutterRoot)

    # Flutter 3.24.5 only maps VS major versions 16/17. Its prebuilt tool
    # therefore asks CMake 4.4 to use the obsolete VS2019 generator on VS2026.
    # The VS2026 generator has the same byte length, so patch the cached Dart
    # snapshot without requiring a Flutter SDK rebuild.
    $snapshot = Join-Path $FlutterRoot "bin\cache\flutter_tools.snapshot"
    if (-not (Test-Path -LiteralPath $snapshot)) {
        throw "Flutter tool snapshot was not found at $snapshot."
    }

    $bytes = [IO.File]::ReadAllBytes($snapshot)
    $patched = $false
    foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
        $old = $encoding.GetBytes("Visual Studio 16 2019")
        $new = $encoding.GetBytes("Visual Studio 18 2026")
        if (Replace-ByteSequence $bytes $old $new) {
            $patched = $true
            break
        }
        if (Replace-ByteSequence $bytes $new $new) {
            Write-Host "Flutter snapshot already uses the Visual Studio 18 2026 generator."
            return
        }
    }

    if (-not $patched) {
        throw "Flutter snapshot does not contain a Visual Studio 16 2019 generator string."
    }
    [IO.File]::WriteAllBytes($snapshot, $bytes)
    Write-Host "Patched Flutter snapshot to use the Visual Studio 18 2026 generator."
}

function Apply-FlutterPatch {
    param(
        [Parameter(Mandatory = $true)][string]$FlutterRoot,
        [Parameter(Mandatory = $true)][string]$PatchPath
    )

    $dropdownPath = Join-Path $FlutterRoot "packages\flutter\lib\src\material\dropdown_menu.dart"
    if (-not (Test-Path -LiteralPath $dropdownPath)) {
        throw "Flutter dropdown_menu.dart was not found at $dropdownPath."
    }

    $dropdownSource = Get-Content -LiteralPath $dropdownPath -Raw
    if ($dropdownSource -match "late bool _enableFilter") {
        Invoke-Checked "git" @("-C", $FlutterRoot, "apply", $PatchPath)
        return
    }

    if ($dropdownSource -notmatch "bool _enableFilter = false") {
        throw "Flutter $flutterVersion does not match the expected dropdown menu patch context."
    }

    Write-Host "Flutter dropdown filter patch is already applied."
}

function Install-BridgeCodegen {
    $bridgeCommand = Get-Command flutter_rust_bridge_codegen -ErrorAction SilentlyContinue
    if ($null -eq $bridgeCommand) {
        Invoke-Checked "cargo" @("+$rustVersion", "install", "flutter_rust_bridge_codegen", "--version", $bridgeVersion, "--features", "uuid", "--locked")
        return
    }

    $bridgeOutput = (& flutter_rust_bridge_codegen --version 2>&1 | Out-String).Trim()
    if ($bridgeOutput -notmatch [regex]::Escape($bridgeVersion)) {
        Invoke-Checked "cargo" @("+$rustVersion", "install", "flutter_rust_bridge_codegen", "--version", $bridgeVersion, "--features", "uuid", "--locked", "--force")
    }
}

function Add-UsbDriver {
    param(
        [Parameter(Mandatory = $true)][string]$PortablePath,
        [Parameter(Mandatory = $true)][string]$WorkPath
    )

    $archive = Join-Path $WorkPath "usbmmidd_v2.zip"
    $extract = Join-Path $WorkPath "usbmmidd-extract"
    Download-File "https://github.com/rustdesk-org/rdev/releases/download/usbmmidd_v2/usbmmidd_v2.zip" $archive
    Remove-Directory $extract
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force

    $driverRoot = Get-ChildItem -LiteralPath $extract -Directory -Recurse |
        Where-Object { $_.Name -eq "usbmmidd_v2" } |
        Select-Object -First 1
    if ($null -eq $driverRoot) {
        throw "usbmmidd_v2.zip did not contain a usbmmidd_v2 directory."
    }

    Remove-Directory (Join-Path $driverRoot.FullName "Win32")
    @("deviceinstaller64.exe", "deviceinstaller.exe", "usbmmidd.bat") | ForEach-Object {
        $file = Join-Path $driverRoot.FullName $_
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force
        }
    }
    Copy-Item -Path (Join-Path $driverRoot.FullName "*") -Destination $PortablePath -Recurse -Force
}

function Add-PrinterDriver {
    param(
        [Parameter(Mandatory = $true)][string]$PortablePath,
        [Parameter(Mandatory = $true)][string]$WorkPath
    )

    try {
        $driverArchive = Join-Path $WorkPath "rustdesk_printer_driver_v4-1.4.zip"
        $adapterArchive = Join-Path $WorkPath "printer_driver_adapter.zip"
        $checksums = Join-Path $WorkPath "sha256sums"
        Download-File "https://github.com/rustdesk/hbb_common/releases/download/driver/rustdesk_printer_driver_v4-1.4.zip" $driverArchive
        Download-File "https://github.com/rustdesk/hbb_common/releases/download/driver/printer_driver_adapter.zip" $adapterArchive
        Download-File "https://github.com/rustdesk/hbb_common/releases/download/driver/sha256sums" $checksums

        $sumText = Get-Content -LiteralPath $checksums -Raw
        $driverExpected = ([regex]::Match($sumText, "(?m)^([a-fA-F0-9]{64}) \*rustdesk_printer_driver_v4-1.4\.zip$")).Groups[1].Value
        $adapterExpected = ([regex]::Match($sumText, "(?m)^([a-fA-F0-9]{64}) \*printer_driver_adapter\.zip$")).Groups[1].Value
        $driverActual = (Get-FileHash -LiteralPath $driverArchive -Algorithm SHA256).Hash
        $adapterActual = (Get-FileHash -LiteralPath $adapterArchive -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($driverExpected) -or [string]::IsNullOrWhiteSpace($adapterExpected) -or
            $driverExpected.ToUpperInvariant() -ne $driverActual.ToUpperInvariant() -or
            $adapterExpected.ToUpperInvariant() -ne $adapterActual.ToUpperInvariant()) {
            Write-Warning "Printer driver checksum verification failed; skipping optional printer files."
            return
        }

        $driverExtract = Join-Path $WorkPath "printer-driver-extract"
        $adapterExtract = Join-Path $WorkPath "printer-adapter-extract"
        Remove-Directory $driverExtract
        Remove-Directory $adapterExtract
        Expand-Archive -LiteralPath $driverArchive -DestinationPath $driverExtract -Force
        Expand-Archive -LiteralPath $adapterArchive -DestinationPath $adapterExtract -Force

        $driverFolder = Get-ChildItem -LiteralPath $driverExtract -Directory -Recurse |
            Where-Object { $_.Name -eq "rustdesk_printer_driver_v4-1.4" } |
            Select-Object -First 1
        if ($null -eq $driverFolder) {
            throw "Verified printer driver archive did not contain its expected directory."
        }

        $destinationDrivers = Join-Path $PortablePath "drivers\RustDeskPrinterDriver"
        New-Item -ItemType Directory -Path $destinationDrivers -Force | Out-Null
        Copy-Item -Path (Join-Path $driverFolder.FullName "*") -Destination $destinationDrivers -Recurse -Force

        $adapter = Get-ChildItem -LiteralPath $adapterExtract -File -Recurse |
            Where-Object { $_.Name -eq "printer_driver_adapter.dll" } |
            Select-Object -First 1
        if ($null -eq $adapter) {
            throw "Verified printer adapter archive did not contain printer_driver_adapter.dll."
        }
        Copy-Item -LiteralPath $adapter.FullName -Destination $PortablePath -Force
    }
    catch {
        Write-Warning "Optional printer driver files were skipped: $($_.Exception.Message)"
    }
}

try {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "The Gitea worker must be a 64-bit Windows host."
    }

    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    Initialize-RustToolchain $buildRoot
    Initialize-Flutter $buildRoot
    Initialize-Llvm $buildRoot
    Initialize-WindowsBuildTools
    Initialize-NuGet $buildRoot

    @("git", "python", "cargo", "rustup", "flutter", "clang", "cmake", "ninja", "msbuild", "nuget") | ForEach-Object {
        Require-Command $_
    }
    if ([string]::IsNullOrWhiteSpace($env:VCPKG_ROOT)) {
        Write-Host "VCPKG_ROOT is not configured; a workspace-local vcpkg checkout will be used."
    }

    Remove-Directory $stage
    Remove-Directory $packerRoot
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $flutterCommand = Get-Command flutter
    $flutterPath = if (-not [string]::IsNullOrWhiteSpace($flutterCommand.Source)) { $flutterCommand.Source } else { $flutterCommand.Definition }
    $flutterRoot = Split-Path (Split-Path $flutterPath -Parent) -Parent
    Patch-FlutterVisualStudioGenerator $flutterRoot
    $flutterVersionOutput = (& flutter --version 2>&1 | Out-String).Trim()
    Write-Host $flutterVersionOutput
    if ($flutterVersionOutput -notmatch [regex]::Escape($flutterVersion)) {
        throw "Flutter $flutterVersion is required, but the runner reported: $flutterVersionOutput"
    }

    $flutterPatch = Join-Path $repo ".github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff"
    Apply-FlutterPatch $flutterRoot $flutterPatch
    & flutter doctor -v
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "flutter doctor reported optional platform issues; continuing with the Windows build."
    }
    Invoke-Checked "flutter" @("precache", "--windows")

    $engineArchive = Join-Path $buildRoot "windows-x64-release.zip"
    $engineExtract = Join-Path $buildRoot "windows-x64-release"
    Download-File "https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip" $engineArchive
    Remove-Directory $engineExtract
    Expand-Archive -LiteralPath $engineArchive -DestinationPath $engineExtract -Force
    $engineDestination = Join-Path $flutterRoot "bin\cache\artifacts\engine\windows-x64-release"
    New-Item -ItemType Directory -Path $engineDestination -Force | Out-Null
    Copy-Item -Path (Join-Path $engineExtract "*") -Destination $engineDestination -Recurse -Force

    Invoke-Checked "rustup" @("toolchain", "install", $rustVersion, "--profile", "minimal")
    Invoke-Checked "rustup" @("target", "add", $rustTarget, "--toolchain", $rustVersion)
    $env:RUSTUP_TOOLCHAIN = $rustVersion
    $cargoBin = Join-Path $env:CARGO_HOME "bin"
    if ($env:Path -notlike "*$cargoBin*") {
        $env:Path = "$cargoBin;$env:Path"
    }
    $env:VCPKG_DEFAULT_TRIPLET = $vcpkgTriplet
    $env:VCPKG_DEFAULT_HOST_TRIPLET = $vcpkgTriplet
    Write-Host "Expected LLVM/Clang version: $llvmVersion"
    Invoke-Checked "clang" @("--version")

    if (-not (Get-Command cargo-expand -ErrorAction SilentlyContinue)) {
        Invoke-Checked "cargo" @("+$rustVersion", "install", "cargo-expand", "--version", $cargoExpandVersion, "--locked")
    }
    Install-BridgeCodegen
    Push-Location (Join-Path $repo "flutter")
    Invoke-Checked "flutter" @("pub", "get")
    Pop-Location
    Invoke-Checked "flutter_rust_bridge_codegen" @(
        "--rust-input", (Join-Path $repo "src\flutter_ffi.rs"),
        "--dart-output", (Join-Path $repo "flutter\lib\generated_bridge.dart"),
        "--c-output", (Join-Path $repo "flutter\macos\Runner\bridge_generated.h")
    )
    Copy-Item (Join-Path $repo "flutter\macos\Runner\bridge_generated.h") (Join-Path $repo "flutter\ios\Runner\bridge_generated.h") -Force

    $vcpkgRoot = Get-VcpkgRoot $buildRoot
    Set-VcpkgNasmVersion $vcpkgRoot
    $env:VCPKG_ROOT = $vcpkgRoot
    $vcpkg = Join-Path $vcpkgRoot "vcpkg.exe"
    if ([string]::IsNullOrWhiteSpace($env:VCPKG_MAX_CONCURRENCY)) {
        $env:VCPKG_MAX_CONCURRENCY = "1"
    }
    Write-Host "Using vcpkg concurrency limit $env:VCPKG_MAX_CONCURRENCY."
    try {
        Push-Location $repo
        Invoke-Checked $vcpkg @("install", "--triplet", $vcpkgTriplet, "--x-install-root=$(Join-Path $vcpkgRoot 'installed')")
        Pop-Location
    }
    catch {
        Write-Host "vcpkg installation failed; recent logs:"
        Get-ChildItem -LiteralPath (Join-Path $vcpkgRoot "buildtrees") -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq ".log" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5 |
            ForEach-Object { Write-Host "--- $($_.FullName)"; Get-Content -LiteralPath $_.FullName -Tail 80 }
        throw
    }

    Push-Location $repo
    Invoke-Checked "python" @("build.py", "--portable", "--flutter", "--skip-portable-pack", "--hwcodec", "--vram")
    Pop-Location

    $releaseSource = Join-Path $repo "flutter\build\windows\x64\runner\Release"
    if (-not (Test-Path -LiteralPath (Join-Path $releaseSource "rustdesk.exe"))) {
        throw "Flutter Release output does not contain rustdesk.exe: $releaseSource"
    }
    New-Item -ItemType Directory -Path $portable -Force | Out-Null
    Copy-Item -Path (Join-Path $releaseSource "*") -Destination $portable -Recurse -Force
    Add-UsbDriver $portable $buildRoot
    Add-PrinterDriver $portable $buildRoot

    New-Item -ItemType Directory -Path $packerRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $repo "libs\portable\*") -Destination $packerRoot -Recurse -Force
    # The copied packer lives below the repository workspace, but it is built
    # as a standalone crate. Mark this generated checkout as its own workspace
    # so Cargo does not try to attach it to the root RustDesk workspace.
    $packerManifest = Join-Path $packerRoot "Cargo.toml"
    Add-Content -LiteralPath $packerManifest -Value "`r`n[workspace]`r`n"
    Push-Location $packerRoot
    Invoke-Checked "python" @("-m", "pip", "install", "-r", (Join-Path $packerRoot "requirements.txt"))
    Invoke-Checked "python" @(
        (Join-Path $packerRoot "generate.py"),
        "-f", $portable,
        "-o", $packerRoot,
        "-e", (Join-Path $portable "rustdesk.exe")
    )
    Pop-Location
    $packer = Join-Path $packerRoot "target\release\rustdesk-portable-packer.exe"
    if (-not (Test-Path -LiteralPath $packer)) {
        throw "Portable packer executable was not created."
    }
    $portableExe = Join-Path $stage "rustdesk-windows-x64-portable.exe"
    Copy-Item -LiteralPath $packer -Destination $portableExe -Force

    $manifest = Join-Path $repo "res\manifest.xml"
    $manifestText = Get-Content -LiteralPath $manifest -Raw
    Set-Content -LiteralPath $manifest -Value ($manifestText -replace "(?m)^.*dpiAware.*\r?\n", "") -NoNewline
    Push-Location (Join-Path $repo "res\msi")
    Invoke-Checked "python" @("preprocess.py", "--arp", "-d", $portable)
    Invoke-Checked "nuget" @("restore", "msi.sln")
    Invoke-Checked "msbuild" @("msi.sln", "-p:Configuration=Release", "-p:Platform=x64", "/p:TargetVersion=Windows10")
    Pop-Location

    $msi = Get-ChildItem -LiteralPath (Join-Path $repo "res\msi\Package\bin") -File -Recurse |
        Where-Object { $_.Name -eq "Package.msi" -and $_.FullName -match "\\Release\\en-us\\Package\.msi$" } |
        Select-Object -First 1
    if ($null -eq $msi) {
        throw "MSI build completed without producing Package.msi."
    }
    $msiOutput = Join-Path $stage "rustdesk-windows-x64.msi"
    Copy-Item -LiteralPath $msi.FullName -Destination $msiOutput -Force

    if (-not (Test-Path -LiteralPath (Join-Path $portable "rustdesk.exe"))) {
        throw "Portable executable missing from staged directory."
    }
    if (-not (Test-Path -LiteralPath $portableExe)) {
        throw "Portable self-extracted executable missing from staging."
    }
    if (-not (Test-Path -LiteralPath $msiOutput)) {
        throw "MSI missing from staging."
    }

    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Get-ChildItem -LiteralPath $destination -Force | Remove-Item -Recurse -Force
    Copy-Item -LiteralPath $portable -Destination (Join-Path $destination "rustdesk-windows-x64-portable") -Recurse -Force
    Copy-Item -LiteralPath $portableExe -Destination $destination -Force
    Copy-Item -LiteralPath $msiOutput -Destination $destination -Force

    Write-Host "Build completed. Final outputs:"
    Get-ChildItem -LiteralPath $destination -Force |
        Select-Object FullName, Length, LastWriteTime |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
}
catch {
    Write-Error "Windows Flutter build failed: $($_.Exception.Message)"
    exit 1
}
