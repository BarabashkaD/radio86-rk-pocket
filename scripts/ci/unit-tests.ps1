# The Python unit tests of CI (AGENTS.md section 6, "CI (GitHub Actions)"): every test must run,
# so a skipped test (the Verilog part of test_k1_layout.py without iverilog) fails. Any output line
# with the word "skipped" counts, so no test name or message may contain it.
# Usage, from any directory: pwsh -File scripts/ci/unit-tests.ps1   (iverilog on PATH or IVERILOG set;
# mtools for test_fatcard.py and test_release.py; python -B scripts/fetch_assets.py first)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '../..')
$out = python -B -m unittest -v scripts/tests/test_package.py scripts/tests/test_k1_layout.py scripts/tests/test_check_repo.py scripts/tests/test_core_machine_subset.py scripts/tests/test_romdisk.py scripts/tests/test_card.py scripts/tests/test_fatcard.py scripts/tests/test_frame_compare.py scripts/tests/test_release.py 2>&1
$code = $LASTEXITCODE
$out
if ($code -ne 0) { exit $code }
if ($out -match 'skipped') { Write-Error 'a test was skipped: iverilog, the fetched assets (python -B scripts/fetch_assets.py) or the core submodule missing'; exit 1 }
exit 0
