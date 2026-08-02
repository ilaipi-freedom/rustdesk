# Gitea Rust Toolchain Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Windows Flutter build script bootstrap Rust independently of the Gitea runner service account's existing PATH.

**Architecture:** Add one PowerShell initializer to the existing build script before prerequisite checks. It uses an optional `RUSTDESK_TOOL_CACHE` or `.gitea-build\tools\rust`, sets process-local `CARGO_HOME`/`RUSTUP_HOME`, downloads `rustup-init.exe` only when needed, installs Rust 1.75 and the Windows MSVC target, then leaves all existing build commands unchanged.

**Tech Stack:** PowerShell, rustup-init, Rust 1.75 MSVC, Windows x64, Gitea Actions.

---

### Task 1: Add process-local Rust bootstrap

**Files:**
- Modify: `.gitea/scripts/build-windows-flutter.ps1` near constants, helper functions, and the main preflight.

- [ ] **Step 1: Add Rust cache constants and installer helper**

  Add `rustTarget`-adjacent constants for the rustup download URL and cache path. Implement `Initialize-RustToolchain` so it sets `$env:CARGO_HOME` to `<cache>\cargo`, `$env:RUSTUP_HOME` to `<cache>\rustup`, prepends `<cache>\cargo\bin` to `$env:Path`, downloads `rustup-init.exe` to the cache when `rustup.exe` is absent, and invokes:

  ```powershell
  & $installer --no-modify-path -y --default-toolchain none --profile minimal
  ```

  Use `Invoke-WebRequest -UseBasicParsing`, `Invoke-Checked`, and terminating errors. Never modify machine/user PATH.

- [ ] **Step 2: Install and verify the pinned toolchain**

  In the same helper, require the cache-local `rustup.exe`, run `rustup toolchain install 1.75 --profile minimal`, `rustup target add x86_64-pc-windows-msvc --toolchain 1.75`, then verify `cargo +1.75 --version`. Re-running the helper must reuse the cache and tolerate an already-installed toolchain.

- [ ] **Step 3: Call bootstrap before the existing command preflight**

  Invoke `Initialize-RustToolchain $buildRoot` immediately after creating `$buildRoot` and before `Require-Command` checks. Keep `cargo` and `rustup` in the required-command list so a failed bootstrap still produces an explicit error. Ensure `Install-BridgeCodegen`, `cargo-expand`, vcpkg, and `build.py` inherit the process-local environment.

- [ ] **Step 4: Static verification and commit**

  Run:

  ```bash
  git diff --check
  rg -n "RUSTDESK_TOOL_CACHE|CARGO_HOME|RUSTUP_HOME|rustup-init|toolchain install|target add" .gitea/scripts/build-windows-flutter.ps1
  git add .gitea/scripts/build-windows-flutter.ps1
  git commit -m "ci: bootstrap Rust toolchain in Gitea builds"
  ```

  Expected: the bootstrap call appears before the preflight array, and no machine PATH mutation is present.

### Task 2: Validate the worker-facing behavior

**Files:**
- No source changes unless static validation identifies a concrete syntax or ordering defect.

- [ ] **Step 1: Verify repository state**

  Run `git status --short`, `git log -3 --oneline`, and `git diff HEAD~1 --check`. Expected: clean worktree and only the Rust bootstrap commit after the design/plan commits.

- [ ] **Step 2: Push the bootstrap commit to Gitea**

  Run `git push gitea master` and confirm `git ls-remote gitea refs/heads/master` equals the local HEAD.

- [ ] **Step 3: Inspect the latest Actions log**

  Run:

  ```bash
  /Users/billy/.codex/skills/jwzn-server-operations/scripts/jwzn-gitea-logs.sh actions jwzn/jwvisdesk
  ```

  Expected: the log reaches Rust toolchain initialization and no longer fails with `Required command 'cargo' was not found on PATH`; report the first new error if the next prerequisite is missing.

