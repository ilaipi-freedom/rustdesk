param(
    [Parameter(Mandatory = $true)][string]$PortablePath,
    [Parameter(Mandatory = $false)][string]$AppName = "JwVisDesk"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $PortablePath -PathType Container)) {
    throw "Portable staging directory was not found: $PortablePath"
}
if ([string]::IsNullOrWhiteSpace($env:NETWORK_CONFIG)) {
    throw "NETWORK_CONFIG secret is required to build $AppName."
}

$sourceExecutable = Join-Path $PortablePath "rustdesk.exe"
$appExecutable = "$AppName.exe"
$targetExecutable = Join-Path $PortablePath $appExecutable
if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
    throw "Flutter Release output does not contain rustdesk.exe: $PortablePath"
}
if (Test-Path -LiteralPath $targetExecutable) {
    Remove-Item -LiteralPath $targetExecutable -Force
}
Rename-Item -LiteralPath $sourceExecutable -NewName $appExecutable

$config = [ordered]@{
    "app-name" = $AppName
    "network-config" = $env:NETWORK_CONFIG
    "override-settings" = [ordered]@{
        "access-mode" = "full"
        "enable-remote-printer" = "N"
        "hide-network-settings" = "Y"
        "hide-server-settings" = "Y"
        "hide-proxy-settings" = "Y"
        "hide-websocket-settings" = "Y"
        "hide-remote-printer-settings" = "Y"
    }
}
$configPath = Join-Path $PortablePath "jwvisdesk-config.json"
$json = $config | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($configPath, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Prepared $AppName staging directory and wrote sidecar configuration."
