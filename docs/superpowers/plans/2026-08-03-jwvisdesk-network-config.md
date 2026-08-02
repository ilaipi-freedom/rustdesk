# JwVisDesk Network Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows x64 JwVisDesk package that embeds the Gitea `NETWORK_CONFIG` and installs with a distinct executable/product identity.

**Architecture:** Reuse RustDesk's existing custom-server decoder at runtime. The PowerShell workflow writes an adjacent JSON sidecar, renames the Flutter executable to `JwVisDesk.exe`, and passes the renamed file to the portable packer and MSI preprocessor.

**Tech Stack:** Rust, serde_json, PowerShell, Gitea Actions, WiX/MSBuild, Python portable packer.

---

### Task 1: Add decoder and configuration-application tests

**Files:**
- Modify: `src/custom_server.rs`
- Modify: `src/common.rs`

- [ ] Add a test that creates JSON `{\"host\":\"id.example\",\"relay\":\"relay.example\",\"api\":\"https://api.example\",\"key\":\"secret\"}`, encodes it as unpadded Base64URL, reverses the encoded characters, and verifies `get_custom_server_from_string` returns all four fields.
- [ ] Add a configuration-application test that verifies network fields land in `OVERWRITE_SETTINGS`, `access-mode` is `full`, `hide-network-settings` is `Y`, and `is_option_fixed("access-mode")` is true after applying a sidecar-like map.
- [ ] Run the focused tests and confirm they fail because sidecar application is not implemented yet.

### Task 2: Implement shared custom configuration application and sidecar loading

**Files:**
- Modify: `src/common.rs`
- Modify: `src/flutter_ffi.rs`

- [ ] Extract the existing decoded custom-client map application into a reusable function.
- [ ] Keep signed `custom.txt` behavior unchanged by calling the reusable function after signature verification.
- [ ] Add a release executable-directory/debug working-directory loader for `jwvisdesk-config.json`.
- [ ] Decode the sidecar's `network-config` through `get_custom_server_from_string`, insert the four official override keys, force `app-name` to `JwVisDesk`, and apply the fixed/default/hidden settings.
- [ ] Load the sidecar after official custom configuration in core, Flutter FFI, and service startup paths.
- [ ] Re-run focused tests and the full library test suite.

### Task 3: Update Windows packaging

**Files:**
- Modify: `.gitea/workflows/build-windows-flutter.yml`
- Modify: `.gitea/scripts/build-windows-flutter.ps1`

- [ ] Pass `${{ secrets.NETWORK_CONFIG }}` into the job environment without printing it.
- [ ] Require a non-empty secret and write a UTF-8 `jwvisdesk-config.json` into the staged portable directory after copying Flutter Release output.
- [ ] Rename only the staged executable from `rustdesk.exe` to `JwVisDesk.exe`; use the renamed path for packer, MSI preprocess, validation, and final output names.
- [ ] Invoke MSI preprocessing with `--custom --app-name JwVisDesk` and keep the existing optional driver files.
- [ ] Copy `JwVisDesk.exe`, portable self-extractor, and MSI to `D:\work\YYM\release\jwvisdesk`.

### Task 4: Verify, commit, push, and inspect Gitea Actions

**Files:**
- Review all changed files and generated diffs.

- [ ] Run `cargo fmt --check`, focused/full Rust tests, Python compilation, YAML parse/inspection, and PowerShell structural checks available on macOS.
- [ ] Commit with `feat: inject JwVisDesk network configuration`.
- [ ] Push `master` to `gitea`.
- [ ] Wait at least 30 seconds, then use the JWZN Gitea log helper to inspect the latest Actions run and report the first decisive error or successful artifact stage.
