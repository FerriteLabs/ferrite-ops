$ErrorActionPreference = "Stop"

$rootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $rootDir

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host "cargo is required. Install Rust from https://rustup.rs/ and retry."
    Write-Host ""
    Write-Host "No Rust toolchain? Use Docker:"
    Write-Host "  docker compose up -d"
    Write-Host "  docker compose exec -T ferrite ferrite-cli PING"
    exit 1
}

$configPath = if ($env:FERRITE_CONFIG) { $env:FERRITE_CONFIG } else { "ferrite.toml" }
$dataDir = if ($env:FERRITE_DATA_DIR) { $env:FERRITE_DATA_DIR } else { ".\data" }

$configDir = Split-Path -Parent $configPath
if ($configDir -and -not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir | Out-Null
}

cargo build --release --bin ferrite --bin ferrite-cli

$ferriteExe = Join-Path $rootDir "target\release\ferrite.exe"

if (-not (Test-Path $configPath)) {
    & $ferriteExe init --output $configPath --data-dir $dataDir
}

& $ferriteExe --config $configPath
