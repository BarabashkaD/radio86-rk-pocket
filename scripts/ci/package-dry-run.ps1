# The package dry run of CI (AGENTS.md section 6, "CI (GitHub Actions)"): package.py with a
# 256-byte stand-in ap_core.rbf, so the definitions, the assets, the zip layout and the openFPGA
# library rules are checked without a Quartus build. The zip holds the stand-in bitstream: never
# upload or publish it. Work folder: <RUNNER_TEMP>/package-dry-run in CI, else
# build/ci-local/tmp/package-dry-run (emptied first). Needs the core submodule; not build/assets
# (the package holds no ROM disk image, ROMDISKS.txt says where to get them).
# Usage, from any directory: pwsh -File scripts/ci/package-dry-run.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location $root
$base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { Join-Path $root 'build/ci-local/tmp' }
$work = Join-Path $base 'package-dry-run'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
$build = Join-Path $work 'stand-in'
New-Item -ItemType Directory -Force (Join-Path $build 'output_files') | Out-Null
[IO.File]::WriteAllBytes((Join-Path $build 'output_files/ap_core.rbf'), [byte[]](0..255))
python -B scripts/package.py --version 0.0.0-ci --date 2000-01-01 --build $build --output (Join-Path $work 'package')
exit $LASTEXITCODE
