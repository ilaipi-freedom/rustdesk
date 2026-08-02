# Gitea Windows Flutter Build

## Goal

Add a Gitea Actions workflow that builds the x64 Windows Flutter edition of RustDesk on the existing `gitea-worker` runner. The workflow must leave the build workspace available for diagnostics, but copy only final distributable outputs to `D:\work\YYM\release\jwvisdesk`.

## Scope

- Build only `x86_64-pc-windows-msvc`.
- Use the repository's Flutter desktop build path with hardware codec and VRAM support.
- Generate the Flutter Rust bridge in the same job, avoiding GitHub artifact/cache services.
- Produce a complete portable directory, a self-extracted portable `.exe`, and an `.msi` installer.
- Do not upload artifacts, publish a release, sign files, or modify repository sources permanently.
- Trigger on `push` and `workflow_dispatch`, matching the existing Sop Gitea workflow convention.

## Files

- `.gitea/workflows/build-windows-flutter.yml`: Gitea workflow using `runs-on: gitea-worker`, checkout, and an explicit `cmd` step invoking PowerShell.
- `.gitea/scripts/build-windows-flutter.ps1`: reusable build script containing prerequisite checks, bridge generation, dependency setup, compilation, packaging, and publication.

## Build flow

1. Validate that the runner is Windows x64 and that required tools are available: Git, Python, Flutter, Rust/Cargo, LLVM/Clang, CMake/Ninja, vcpkg, NuGet, and MSBuild/WiX dependencies.
2. Check out submodules through `actions/checkout@v4`.
3. Install or select the pinned Flutter `3.24.5` SDK and apply the repository's Flutter dropdown patch.
4. Generate bridge sources using `flutter_rust_bridge_codegen 1.80.1` and run `flutter pub get`.
5. Select Rust `1.75`, target `x86_64-pc-windows-msvc`, and vcpkg commit `120deac3062162151622ca4860575a33844ba10b`; install the `x64-windows-static` dependencies.
6. Run `python build.py --portable --flutter --skip-portable-pack --hwcodec --vram`.
7. Copy Flutter's Release directory to a temporary portable output, add the USB display driver and verified printer-driver files, and retain the complete directory as a final output.
8. Build the self-extracted portable executable with `libs/portable/generate.py`.
9. Preprocess and build `res/msi/msi.sln` with MSBuild for x64, then collect `Package.msi`.
10. After all outputs succeed, replace the contents of `D:\work\YYM\release\jwvisdesk` with:
    - `rustdesk-windows-x64-portable\` (complete portable directory)
    - `rustdesk-windows-x64-portable.exe`
    - `rustdesk-windows-x64.msi`

The destination is created if absent. Existing destination contents are removed only after a successful build has produced all expected outputs; a failed build does not touch it.

## Error handling and compatibility

- PowerShell uses terminating errors and explicit exit-code checks; missing prerequisites fail early with an actionable message.
- Downloads are checked where upstream provides checksums. Optional printer-driver download failures are logged and do not prevent the core build, matching the official workflow.
- The workflow avoids GitHub-only actions such as artifact transfer, release upload, and GitHub Actions cache variables.
- Tool paths may be supplied through existing runner environment variables (`VCPKG_ROOT`, `FLUTTER_ROOT`, Rust and LLVM `PATH` entries). The script will not overwrite system-wide tool installations.

## Verification

- Validate YAML structure and PowerShell syntax locally where tools are available.
- Confirm the script checks for the three expected final outputs before publishing.
- Confirm the destination is not modified when compilation or packaging fails.
- The actual compile/package verification must run on the user's `gitea-worker`, because this development environment is not the Windows runner.
