# Gitea Rust Toolchain Bootstrap

## Goal

Make the Windows Flutter build script self-sufficient from the Rust toolchain onward. The script must work when the Gitea runner service account cannot see the interactive user's Rust installation or PATH.

## Scope

- Keep Python as a runner prerequisite; the worker already provides it.
- Bootstrap Rust with the official `rustup-init.exe` when `rustup`/`cargo` are unavailable.
- Install Rust `1.75` and target `x86_64-pc-windows-msvc`.
- Store the bootstrap installation under a workspace-local tool directory and add its Cargo bin directory to the current process PATH only.
- Reuse an existing compatible Rust installation when available.
- Leave Visual Studio/MSBuild, Flutter, LLVM/Clang, CMake, Ninja, NuGet, and Git as runner prerequisites.

## Design

Add a self-contained `Initialize-RustToolchain` function to `.gitea/scripts/build-windows-flutter.ps1` before the command preflight. It will:

1. Define `RUSTDESK_TOOL_CACHE` as an optional persistent cache root; otherwise use `.gitea-build\tools` in the checkout.
2. Set `CARGO_HOME` and `RUSTUP_HOME` below the Rust cache root so installation is independent of the service account's user profile.
3. Prepend the cache's Cargo bin directory to the current process `PATH`.
4. If the cache does not contain `rustup.exe`, download the pinned-host `rustup-init.exe` from `static.rust-lang.org` and run it with `--no-modify-path --default-toolchain none --profile minimal`.
5. Install or reuse Rust `1.75` and add `x86_64-pc-windows-msvc` using `rustup`.
6. Verify both `rustup --version` and `cargo +1.75 --version` before the existing bridge and build steps continue.

The workflow remains unchanged. No system-wide PATH or user profile is modified, and the destination output directory is unaffected by tool installation.

## Failure handling

- Download, installer, toolchain, target, or verification failures stop the job with the exact command and exit code.
- Existing system Rust may be used only when its commands are available and the requested toolchain can be selected; otherwise the local bootstrap is used.
- The script prints the cache root and selected toolchain without printing credentials or environment secrets.

## Verification

- Static checks confirm Rust bootstrap runs before the `cargo` preflight and that all later Cargo commands inherit `CARGO_HOME`, `RUSTUP_HOME`, and PATH.
- The Gitea workflow must be rerun on a worker without Rust in its service PATH; success criterion is passing the prerequisite phase and reaching Flutter bridge generation.
- Full MSI/portable packaging remains runner-only verification.
