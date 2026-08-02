# Gitea Windows Flutter Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Gitea Actions workflow and reusable PowerShell script that builds the x64 Windows Flutter package and publishes MSI, portable EXE, and the complete portable directory to `D:\work\YYM\release\jwvisdesk`.

**Architecture:** Keep one Gitea job on `gitea-worker`; the workflow performs checkout and invokes a repository script with `cmd`/PowerShell. The script owns all build logic, uses the runner's preinstalled toolchain and `VCPKG_ROOT`, stages outputs in the Gitea workspace, and only replaces the destination after all expected outputs exist.

**Tech Stack:** Gitea Actions YAML, PowerShell 5+/7, Flutter 3.24.5, flutter_rust_bridge_codegen 1.80.1, Rust 1.75 MSVC, vcpkg x64-windows-static, Python, MSBuild/WiX.

---

### Task 1: Add the Gitea workflow entrypoint

**Files:**
- Create: `.gitea/workflows/build-windows-flutter.yml`

- [ ] **Step 1: Write the minimal workflow**

  Create a workflow with `push` and `workflow_dispatch` triggers, `runs-on: gitea-worker`, recursive checkout, and an explicit Windows command shell invocation:

  ```yaml
  name: Build Windows Flutter package

  on:
    push:
    workflow_dispatch:

  jobs:
    build-windows-flutter:
      runs-on: gitea-worker
      steps:
        - name: Checkout source code
          uses: actions/checkout@v4
          with:
            submodules: recursive

        - name: Build and publish package
          shell: cmd
          run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .gitea\scripts\build-windows-flutter.ps1
  ```

- [ ] **Step 2: Validate YAML shape**

  Run `ruby -e 'require "yaml"; YAML.load_file(".gitea/workflows/build-windows-flutter.yml"); puts "valid"'` if Ruby is available. If the parser treats the YAML 1.1 `on` key as boolean, inspect the file manually and retain the Gitea-compatible workflow syntax.

- [ ] **Step 3: Commit the workflow**

  Run:

  ```bash
  git add .gitea/workflows/build-windows-flutter.yml
  git commit -m "ci: add Gitea Windows Flutter workflow"
  ```

### Task 2: Implement deterministic build and staging script

**Files:**
- Create: `.gitea/scripts/build-windows-flutter.ps1`

- [ ] **Step 1: Add strict PowerShell setup and constants**

  Use `$ErrorActionPreference = 'Stop'`, resolve the repository from `$PSScriptRoot\..\..`, create a workspace-local `gitea-build` staging directory, and define these constants: Flutter `3.24.5`, Rust `1.75`, LLVM `15.0.6`, bridge codegen `1.80.1`, vcpkg commit `120deac3062162151622ca4860575a33844ba10b`, triplet `x64-windows-static`, and destination `D:\work\YYM\release\jwvisdesk`.

- [ ] **Step 2: Add prerequisite and command helpers**

  Implement helpers with explicit failures:

  ```powershell
  function Require-Command([string] $Name) {
      if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
          throw "Required command '$Name' was not found on PATH."
      }
  }

  function Invoke-Checked([string] $FilePath, [string[]] $Arguments) {
      & $FilePath @Arguments
      if ($LASTEXITCODE -ne 0) {
          throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
      }
  }
  ```

  Check Windows x64, `python`, `cargo`, `rustup`, `flutter`, `cmake`, `ninja`, `msbuild`, `nuget`, and `$env:VCPKG_ROOT`; locate `clang` and `vcpkg.exe` under that root. Do not install or mutate system tool installations.

- [ ] **Step 3: Generate bridge and resolve Flutter dependencies**

  Verify `flutter --version` contains `3.24.5`, apply `.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff` from the Flutter SDK root only when it is not already applied, run `flutter pub get` in `flutter`, install `flutter_rust_bridge_codegen` version `1.80.1` with Cargo if missing, then generate all bridge outputs:

  ```powershell
  Push-Location $repo\flutter
  Invoke-Checked "flutter" @("pub", "get")
  Pop-Location
  Invoke-Checked "flutter_rust_bridge_codegen" @(
      "--rust-input", "$repo\src\flutter_ffi.rs",
      "--dart-output", "$repo\flutter\lib\generated_bridge.dart",
      "--c-output", "$repo\flutter\macos\Runner\bridge_generated.h"
  )
  Copy-Item "$repo\flutter\macos\Runner\bridge_generated.h" "$repo\flutter\ios\Runner\bridge_generated.h" -Force
  ```

- [ ] **Step 4: Configure Rust and vcpkg, then compile Flutter**

  Run `rustup toolchain install 1.75`, `rustup target add x86_64-pc-windows-msvc --toolchain 1.75`, select the toolchain for the command, set `VCPKG_DEFAULT_TRIPLET`/`VCPKG_DEFAULT_HOST_TRIPLET` to `x64-windows-static`, run `vcpkg install --triplet x64-windows-static --x-install-root="$env:VCPKG_ROOT\installed"`, and execute:

  ```powershell
  Push-Location $repo
  Invoke-Checked "python" @("build.py", "--portable", "--flutter", "--skip-portable-pack", "--hwcodec", "--vram")
  Pop-Location
  ```

- [ ] **Step 5: Stage the complete portable directory and optional drivers**

  Copy `flutter\build\windows\x64\runner\Release` into a clean workspace-local `portable` directory. Download and extract `usbmmidd_v2.zip`, remove its `Win32`, installer executable, and batch file as in the official workflow, and merge the remaining files. Download the two printer-driver archives and `sha256sums`; compare SHA-256 values before extracting into `portable\drivers` and `portable\printer_driver_adapter.dll`. Log and continue if only the optional printer-driver downloads fail.

- [ ] **Step 6: Build the self-extracted EXE and MSI**

  Remove `dpiAware` from `res\manifest.xml` in the workspace copy, install `libs\portable\requirements.txt`, and run `libs\portable\generate.py -f <portable> -o <portable-packer-output> -e <portable>\rustdesk.exe`. Copy the generated packer executable to the staging root as `rustdesk-windows-x64-portable.exe`.

  In `res\msi`, run `python preprocess.py --arp -d <portable>`, `nuget restore msi.sln`, and `msbuild msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10`. Locate `Package\bin\*\Release\en-us\Package.msi` and copy it to `rustdesk-windows-x64.msi`.

- [ ] **Step 7: Verify staged outputs and publish atomically**

  Require all three staged outputs before touching the destination:

  ```powershell
  if (-not (Test-Path "$stage\rustdesk-windows-x64-portable\rustdesk.exe")) { throw "Portable executable missing." }
  if (-not (Test-Path "$stage\rustdesk-windows-x64-portable.exe")) { throw "Portable packer missing." }
  if (-not (Test-Path "$stage\rustdesk-windows-x64.msi")) { throw "MSI missing." }
  ```

  Create `D:\work\YYM\release\jwvisdesk` if needed, remove its previous contents only after verification, copy the portable directory and two files, and print their paths and sizes.

- [ ] **Step 8: Commit the script**

  Run:

  ```bash
  git add .gitea/scripts/build-windows-flutter.ps1
  git commit -m "ci: add Windows Flutter packaging script"
  ```

### Task 3: Static verification and handoff

**Files:**
- Modify: `.gitea/workflows/build-windows-flutter.yml` only if validation finds syntax issues.
- Modify: `.gitea/scripts/build-windows-flutter.ps1` only if parser/lint checks find issues.

- [ ] **Step 1: Run repository-side checks**

  Run `git diff --check`, `git status --short`, and `git log -2 --oneline`. On a Windows machine, run `powershell.exe -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('.gitea/scripts/build-windows-flutter.ps1',[ref]$null,[ref]$null); 'PowerShell syntax valid'"`.

- [ ] **Step 2: Review destination safety**

  Confirm the script contains no deletion of `D:\work\YYM\release\jwvisdesk` before all three outputs have passed existence checks, and that no `actions/upload-artifact`, release upload, or signing step is present.

- [ ] **Step 3: Document runner-only verification**

  Report that actual compilation must be tested by manually dispatching the Gitea workflow on `gitea-worker`; record the first failure's missing tool or path and adjust only the script's prerequisite/path handling.
