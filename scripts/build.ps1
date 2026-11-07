# Builds the core with Quartus Prime Lite 25.1std (spec 8, D9) in a build directory outside
# the source tree: scripts/build.ps1 [-BuildDir <dir>] [-QuartusRoot <quartus dir>]
param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\build\quartus'),
    [string]$QuartusRoot = $env:QUARTUS_ROOT
)
$ErrorActionPreference = 'Stop'
if (-not $QuartusRoot) {
    $found = (Get-Command quartus_sh -ErrorAction SilentlyContinue).Source
    if ($found) { $QuartusRoot = Split-Path (Split-Path $found) }
}
if (-not $QuartusRoot) { throw 'Quartus not found: set QUARTUS_ROOT to the quartus directory, or put quartus_sh on PATH' }
$sh = Join-Path $QuartusRoot 'bin64\quartus_sh.exe'
$version = (& $sh --version | Out-String)
if ($version -notmatch '25\.1std') { throw "Quartus Prime Lite 25.1std is required (D9); found: $version" }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Force $BuildDir | Out-Null
& $sh -t (Join-Path $repo 'fpga\quartus\create_project.tcl') $BuildDir
if ($LASTEXITCODE) { throw 'create_project.tcl failed' }
Push-Location $BuildDir
try {
    & $sh --flow compile ap_core 2>&1 | Tee-Object (Join-Path $BuildDir 'compile.log')
    if ($LASTEXITCODE) { throw 'Quartus compilation failed' }
} finally { Pop-Location }
python -B (Join-Path $repo 'scripts\check_build.py') $BuildDir
if ($LASTEXITCODE) { throw 'the build check failed' }