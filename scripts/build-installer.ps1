[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version = '0.2.1',
    [switch] $SkipZigBuild,
    [switch] $SkipGoBuild,
    [switch] $CleanReleases
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\installer'))
$distRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
if (-not $buildRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe build directory: $buildRoot"
}

$python = Join-Path $repoRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($null -ne $launcher) {
        & $launcher.Source -3 -m venv (Join-Path $repoRoot '.venv')
    } else {
        $launcher = Get-Command python -ErrorAction Stop
        & $launcher.Source -m venv (Join-Path $repoRoot '.venv')
    }
}

& $python -m pip install --disable-pip-version-check -r (Join-Path $repoRoot 'requirements-build.txt')
if ($LASTEXITCODE -ne 0) { throw 'Could not install installer build dependencies.' }
Push-Location $repoRoot
try {
    & $python -m unittest discover -s (Join-Path $repoRoot 'tests') -v
    if ($LASTEXITCODE -ne 0) { throw 'Python CLI tests failed.' }
} finally {
    Pop-Location
}

if (-not $SkipZigBuild) {
    $zig = Get-Command zig -ErrorAction SilentlyContinue
    if ($null -eq $zig) {
        throw 'zig.exe was not found. Add Zig 0.16.0 to PATH or use -SkipZigBuild with existing release artifacts.'
    }
    & $zig.Source build -Doptimize=ReleaseSafe
    if ($LASTEXITCODE -ne 0) { throw 'Zig release build failed.' }
    & $zig.Source build test
    if ($LASTEXITCODE -ne 0) { throw 'Zig tests failed.' }
}

$gateway = Join-Path $repoRoot 'zig-out\bin\achievement-bridge-api.exe'
if (-not $SkipGoBuild) {
    $go = Get-Command go -ErrorAction SilentlyContinue
    if ($null -eq $go) {
        throw 'go.exe was not found. Install Go 1.26+ or use -SkipGoBuild with an existing gateway artifact.'
    }
    Push-Location (Join-Path $repoRoot 'api')
    try {
        & $go.Source test './...'
        if ($LASTEXITCODE -ne 0) { throw 'Go API tests failed.' }
        & $go.Source build -o $gateway '.\cmd\achievement-bridge-api'
        if ($LASTEXITCODE -ne 0) { throw 'Go gateway release build failed.' }
    } finally {
        Pop-Location
    }
}

$core = Join-Path $repoRoot 'zig-out\bin\achievement-bridge.exe'
$cloud = Join-Path $repoRoot 'zig-out\bin\achievement-bridge-cloud.dll'
foreach ($artifact in @($core, $cloud, $gateway)) {
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Missing build artifact: $artifact" }
}

# The public Web UI is a compiled static bundle served by the local Go API.
# Bun is required only while producing a release, never on the user's machine.
$bun = Get-Command bun -ErrorAction SilentlyContinue
if ($null -eq $bun) {
    throw 'bun.exe was not found. Install Bun to build the packaged Web interface.'
}
Push-Location (Join-Path $repoRoot 'frontend')
try {
    & $bun.Source install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Frontend dependency install failed.' }
    & $bun.Source run build
    if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed.' }
} finally {
    Pop-Location
}
$webDist = Join-Path $repoRoot 'frontend\dist'
if (-not (Test-Path -LiteralPath (Join-Path $webDist 'index.html'))) {
    throw "Missing compiled Web UI: $webDist"
}

if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
$pyInstallerDist = New-Item -ItemType Directory -Path (Join-Path $buildRoot 'app') -Force
$icon = Join-Path $buildRoot 'achievement-bridge.ico'
& $python (Join-Path $repoRoot 'scripts\generate_icon.py') $icon
if ($LASTEXITCODE -ne 0) { throw 'Icon generation failed.' }

& $python -m PyInstaller `
    --noconfirm `
    --clean `
    --onedir `
    --console `
    --name 'AchievementBridge-CLI' `
    --icon $icon `
    --collect-submodules 'pystray' `
    --distpath $pyInstallerDist.FullName `
    --workpath (Join-Path $buildRoot 'pyinstaller-work') `
    --specpath $buildRoot `
    (Join-Path $repoRoot 'achievement_bridge_cli.py')
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller build failed.' }

$stage = Join-Path $pyInstallerDist.FullName 'AchievementBridge-CLI'
Copy-Item -LiteralPath $core -Destination $stage
Copy-Item -LiteralPath $cloud -Destination $stage
Copy-Item -LiteralPath $gateway -Destination $stage
Copy-Item -LiteralPath $webDist -Destination (Join-Path $stage 'web') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $repoRoot 'REFERENCES.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $stage

$packagedCli = Join-Path $stage 'AchievementBridge-CLI.exe'
$smokeOutput = & $packagedCli --help 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Packaged CLI smoke test failed.' }
if ($smokeOutput -match 'NotInstalled|Traceback') { throw "Packaged CLI emitted an unexpected warning: $smokeOutput" }

$dotnet = Get-Command dotnet -ErrorAction Stop
& $dotnet.Source tool restore
if ($LASTEXITCODE -ne 0) { throw 'Could not restore the pinned Velopack vpk tool.' }
if ($CleanReleases -and (Test-Path -LiteralPath $distRoot)) {
    if (-not $distRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe release directory: $distRoot"
    }
    Remove-Item -LiteralPath $distRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
& $dotnet.Source tool run vpk -- pack `
    --packId 'YlanzinhoY.AchievementBridge' `
    --packVersion $Version `
    --packDir $stage `
    --mainExe 'AchievementBridge-CLI.exe' `
    --packTitle 'Achievement Bridge' `
    --packAuthors 'YlanzinhoY' `
    --icon $icon `
    --runtime 'win-x64' `
    --channel 'win-x64' `
    --shortcuts 'Desktop,StartMenuRoot' `
    --instLocation 'PerUser' `
    --instLicense (Join-Path $repoRoot 'LICENSE') `
    --instReadme (Join-Path $repoRoot 'README.md') `
    --noPortable `
    --outputDir $distRoot
if ($LASTEXITCODE -ne 0) { throw 'Velopack release build failed.' }

$setup = Get-ChildItem -LiteralPath $distRoot -Filter '*Setup.exe' -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if ($null -eq $setup) { throw "Installer was not created in: $distRoot" }
$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $setup.FullName
Write-Host "Installer: $($setup.FullName)"
Write-Host "SHA256:   $($hash.Hash)"
