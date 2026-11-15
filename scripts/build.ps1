# Builds the core with Quartus Prime Lite 25.1std (spec 8, D9) in a build directory outside
# the source tree: scripts/build.ps1 [-BuildDir <dir>] [-QuartusRoot <quartus dir>]
# Refuses to build when a submodule is not at its gitlink (git submodule status --recursive).
param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\build\quartus'),
    [string]$QuartusRoot = $env:QUARTUS_ROOT
)
$ErrorActionPreference = 'Stop'

# The first line of `git submodule status --recursive` whose submodule is not at its gitlink: '+'
# another commit checked out, '-' not checked out, 'U' a merge conflict; as one error text, or $null.
function Get-SubmoduleProblem {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -cmatch '^([-+U])\S*\s+(\S+)') {
            $what = switch -CaseSensitive ($Matches[1]) {
                '+' { 'is not at its pin' }
                '-' { 'is not checked out' }
                'U' { 'has a merge conflict' }
            }
            return "submodule $($Matches[2]) ${what}: run git submodule update --init --recursive"
        }
    }
    return $null
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# build only from the pinned library commits
$status = & git -C $repo submodule status --recursive 2>&1
if ($LASTEXITCODE) { [Console]::Error.WriteLine("ERROR: git submodule status failed: $($status -join ' ')"); exit 1 }
$problem = Get-SubmoduleProblem -Lines $status
if ($problem) { [Console]::Error.WriteLine("ERROR: $problem"); exit 1 }
if (-not $QuartusRoot) {
    $found = (Get-Command quartus_sh -ErrorAction SilentlyContinue).Source
    if ($found) { $QuartusRoot = Split-Path (Split-Path $found) }
}
if (-not $QuartusRoot) { throw 'Quartus not found: set QUARTUS_ROOT to the quartus directory, or put quartus_sh on PATH' }
$sh = Join-Path $QuartusRoot 'bin64\quartus_sh.exe'
$version = (& $sh --version | Out-String)
if ($version -notmatch '25\.1std') { throw "Quartus Prime Lite 25.1std is required (D9); found: $version" }
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Force $BuildDir | Out-Null
# the machine and its chips from lib/retroMachines (dependencies first), for create_project.tcl
$list = & python -B (Join-Path $repo 'scripts\simrun.py') filelist machines/rk86 --format qsf --relative-to $BuildDir
if ($LASTEXITCODE) { throw "the file list of machines/rk86 failed: $($list -join ' ')" }
[IO.File]::WriteAllText((Join-Path $BuildDir 'rk86_machine16_files.qsf'), (($list -join "`n") + "`n"))
& $sh -t (Join-Path $repo 'fpga\quartus\create_project.tcl') $BuildDir
if ($LASTEXITCODE) { throw 'create_project.tcl failed' }
Push-Location $BuildDir
try {
    & $sh --flow compile ap_core 2>&1 | Tee-Object (Join-Path $BuildDir 'compile.log')
    if ($LASTEXITCODE) { throw 'Quartus compilation failed' }
} finally { Pop-Location }
python -B (Join-Path $repo 'scripts\check_build.py') $BuildDir
if ($LASTEXITCODE) { throw 'the build check failed' }