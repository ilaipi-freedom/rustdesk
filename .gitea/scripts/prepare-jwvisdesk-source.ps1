param(
    [Parameter(Mandatory = $true)][string]$RepoRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = (Resolve-Path $RepoRoot).Path
$configPath = Join-Path $repo "libs\hbb_common\src\config.rs"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "hbb_common config source was not found: $configPath"
}

# hbb_common is a submodule and its lazy configuration statics can be touched
# before the RustDesk crate's custom-client hook runs.  Give this Windows-only
# fork its own storage identity at the earliest possible layer so Config,
# LocalConfig, status, logs, and IPC can never initialize under RustDesk's
# directory even when the Flutter runner or a service reaches them first.
$content = Get-Content -LiteralPath $configPath -Raw
$old = 'pub static ref APP_NAME: RwLock<String> = RwLock::new("RustDesk".to_owned());'
$new = @"
#[cfg(target_os = "windows")]
pub static ref APP_NAME: RwLock<String> = RwLock::new("JwVisDesk".to_owned());
#[cfg(not(target_os = "windows"))]
$old
"@

$alreadyPatched = $content -match [regex]::Escape('pub static ref APP_NAME: RwLock<String> = RwLock::new("JwVisDesk".to_owned());')
if ($alreadyPatched) {
    Write-Host "hbb_common APP_NAME is already initialized as JwVisDesk on Windows."
    exit 0
}

$occurrences = [regex]::Matches($content, [regex]::Escape($old))
if ($occurrences.Count -ne 1) {
    throw "Expected exactly one RustDesk APP_NAME declaration in $configPath, found $($occurrences.Count)."
}

$patched = $content.Replace($old, $new)
[IO.File]::WriteAllText($configPath, $patched, [Text.UTF8Encoding]::new($false))
Write-Host "Patched hbb_common APP_NAME default to JwVisDesk for Windows."
