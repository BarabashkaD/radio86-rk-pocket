<#
.SYNOPSIS
  Hello-world test of the rk86-vvp container over SSH / SCP.
.DESCRIPTION
  Compiles hello.v with the local Icarus Verilog 13.0, rewrites the .vvp so it
  carries no local paths, runs it locally (reference) and in the container
  (scp + ssh), then compares the outputs. Works in Windows PowerShell 5.1 and 7.
.PARAMETER SshHost    Host of the container (default localhost).
.PARAMETER Port       SSH port (default: RK86_VVP_SSH_PORT, else 2222).
.PARAMETER User       Remote user (default sim).
.PARAMETER KeyText    The client private key the container prints on its console (BEGIN to END lines).
                      Default: the RK86_VVP_KEY environment variable; else, when the container runs
                      on this PC, its console log (docker compose logs); else the clipboard.
                      The key is written to a temporary file for this run only and deleted at the end.
.PARAMETER Iverilog   Path to iverilog (default: IVERILOG env variable, else PATH); vvp is taken from the same folder.
.PARAMETER TimeoutSec Time limit of every ssh / scp step.
#>
[CmdletBinding()]
param(
    [string]$SshHost = 'localhost',
    [int]$Port = $(if ($env:RK86_VVP_SSH_PORT) { [int]$env:RK86_VVP_SSH_PORT } else { 2222 }),
    [string]$User = 'sim',
    [string]$KeyText = $env:RK86_VVP_KEY,
    [string]$Iverilog = $env:IVERILOG,
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Continue'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Timings = New-Object System.Collections.Specialized.OrderedDictionary
$Name = 'hello'

function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

# Runs a native program through System.Diagnostics.Process with a time limit.
# Returns @{ ExitCode; Out; Err }. Stops with the step name on a timeout, or on
# a non-zero exit unless -AllowFail is given.
function Invoke-Native {
    param([string]$Step, [string]$Exe, [string[]]$Arguments, [switch]$AllowFail, [int]$Limit = $TimeoutSec)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $ScriptDir
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Limit * 1000)) {
        try { $p.Kill() } catch { }
        throw "STEP '$Step' timed out after $Limit s"
    }
    $p.WaitForExit()
    $res = @{ ExitCode = $p.ExitCode; Out = $so.Result; Err = $se.Result }
    if ($res.ExitCode -ne 0 -and -not $AllowFail) {
        throw "STEP '$Step' failed (exit $($res.ExitCode)):`n$($res.Out)$($res.Err)"
    }
    return $res
}

function SshPath([string]$p) {
    # Path for ssh options: forward slashes; quoted inside the value if it has a space.
    $p = ([System.IO.Path]::GetFullPath($p)) -replace '\\', '/'
    if ($p -match '\s') { return '"' + $p + '"' }
    return $p
}

function Find-KeyBlock([string]$text) {
    # The last private key block (BEGIN to END) in a text, with LF line ends; $null if none.
    if (-not $text) { return $null }
    $m = [regex]::Matches($text, '-----BEGIN OPENSSH PRIVATE KEY-----[\s\S]*?-----END OPENSSH PRIVATE KEY-----')
    if ($m.Count -eq 0) { return $null }
    # Log viewers may prefix each line (Docker Desktop: a timestamp); keep the key part only:
    # the BEGIN / END markers, else the last word of the line (key lines have no spaces).
    $lines = $m[$m.Count - 1].Value -split '\r?\n' | ForEach-Object {
        $l = $_.Trim()
        if ($l -match '(-----(BEGIN|END) OPENSSH PRIVATE KEY-----)') { $Matches[1] }
        elseif ($l -ne '') { ($l -split '\s+')[-1] }
    } | Where-Object { $_ }
    return (($lines -join "`n") + "`n")
}

function Step([string]$Title, [scriptblock]$Body) {
    Write-Host "== $Title"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Body
    $sw.Stop()
    $Timings[$Title] = [math]::Round($sw.Elapsed.TotalSeconds, 2)
}

# Rewrite of a .vvp (README section 5, rules a-d).
function Convert-Vvp([string]$InFile, [string]$OutFile) {
    $lat = [System.Text.Encoding]::GetEncoding(28591)
    $text = [System.IO.File]::ReadAllText($InFile, $lat)
    $lines = $text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $fnLeft = 0   # entries of the :file_names list still to rewrite (each entry is a line "...";)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($i -eq 0 -and $l.StartsWith('#!')) { continue }
        if ($fnLeft -gt 0) {
            $fnLeft -= ([regex]::Matches($l, '"[^"]*"')).Count
            $l = [regex]::Replace($l, '"([^"]*)"', {
                param($m)
                $v = $m.Groups[1].Value
                $b = if ($v -eq 'N/A') { $v } else { ($v -split '[\\/]')[-1] }   # vvp's own placeholder entry
                '"' + $b + '"'
            })
            $out.Add($l); continue
        }
        if ($l -match '^:vpi_module\s+"([^"]*)"\s*;') {
            $b = ($Matches[1] -split '[\\/]')[-1] -replace '\.vpi$', ''
            $out.Add(':vpi_module "' + $b + '";'); continue
        }
        if ($l -match '^:file_names\s+(\d+)\s*;') {
            $fnLeft = [int]$Matches[1]
            $out.Add($l); continue
        }
        $out.Add($l)
    }
    [System.IO.File]::WriteAllText($OutFile, (($out -join "`n")), $lat)
}

function Find-LocalPaths([string]$File) {
    $t = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::GetEncoding(28591))
    $pats = @('[A-Za-z]:[\\/]', '(?m)^/[a-z]/', '"/[a-z]/')
    foreach ($v in @($env:USERPROFILE)) {
        if ($v) { $pats += [regex]::Escape($v); $pats += [regex]::Escape(($v -replace '\\', '/')) }
    }
    if ($env:USERNAME) { $pats += [regex]::Escape($env:USERNAME) }
    if ($env:COMPUTERNAME) { $pats += '(?i)' + [regex]::Escape($env:COMPUTERNAME) }
    $hits = @()
    foreach ($p in $pats) { if ([regex]::IsMatch($t, $p)) { $hits += $p } }
    return $hits
}

$rc = 1
$TmpDir = $null
try {
    # ---- tools
    if (-not $Iverilog) { $Iverilog = 'iverilog' }
    $ivCmd = Get-Command $Iverilog -ErrorAction SilentlyContinue
    if (-not $ivCmd) { throw "iverilog not found: use -Iverilog or set IVERILOG" }
    $IvPath = $ivCmd.Source
    # The Icarus helpers (ivlpp, ivl) need the DLLs next to iverilog on PATH.
    $env:PATH = (Split-Path $IvPath -Parent) + ';' + $env:PATH
    $vvpCand =Join-Path (Split-Path $IvPath -Parent) 'vvp.exe'
    $VvpPath = if (Test-Path $vvpCand) { $vvpCand } else { (Get-Command vvp -ErrorAction Stop).Source }

    # The key comes from the container; on the PC it exists only in this run's temporary folder.
    $TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('rk86-vvp-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
    $KeyFull = Join-Path $TmpDir 'client_ed25519'
    $KnownArg = SshPath (Join-Path $TmpDir 'known_hosts')
    $LogDir = Join-Path $ScriptDir 'logs'
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    $sshOpts = @('-i', ($KeyFull -replace '\\', '/'), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5', '-o', 'LogLevel=ERROR',
        '-o', 'StrictHostKeyChecking=no', '-o', "UserKnownHostsFile=$KnownArg")
    $Remote = "$User@$SshHost"

    function Ssh([string]$Step, [string]$Cmd, [switch]$AllowFail) {
        Invoke-Native -Step $Step -Exe 'ssh' -Arguments ($sshOpts + @('-p', "$Port", $Remote, $Cmd)) -AllowFail:$AllowFail
    }
    function Scp([string]$Step, [string]$From, [string]$To) {
        Invoke-Native -Step $Step -Exe 'scp' -Arguments ($sshOpts + @('-P', "$Port", $From, $To))
    }

    # ---- 1. the key from the container
    Step '1 key' {
        $block = Find-KeyBlock $KeyText
        $src = '-KeyText / RK86_VVP_KEY'
        if (-not $block) {
            # The container runs on this PC: read its console log.
            $lg = Invoke-Native -Step 'docker compose logs' -Exe 'docker' -Arguments @('compose', 'logs', '--no-log-prefix', 'rk86-vvp') -AllowFail
            if ($lg.ExitCode -eq 0) { $block = Find-KeyBlock $lg.Out; $src = 'the local container console' }
        }
        if (-not $block) {
            try { $block = Find-KeyBlock ((Get-Clipboard -Raw) | Out-String); $src = 'the clipboard' } catch { }
        }
        if (-not $block) {
            throw ("STEP 'key': no client key. Open the container's console (Docker Desktop: the container, Logs; " +
                "or 'docker compose logs rk86-vvp' on its host), copy the lines from BEGIN to END, then run again " +
                "(it reads the clipboard), or pass them with -KeyText / RK86_VVP_KEY")
        }
        Write-Host "key from $src"
        [System.IO.File]::WriteAllText($KeyFull, $block, (New-Object System.Text.ASCIIEncoding))
        # OpenSSH refuses a key file that other accounts can read.
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = Invoke-Native -Step 'icacls' -Exe 'icacls' -Arguments @($KeyFull, '/inheritance:r', '/grant:r', "*${sid}:F")
        $chk = Invoke-Native -Step 'key check' -Exe 'ssh-keygen' -Arguments @('-y', '-P', '', '-f', $KeyFull) -AllowFail
        if ($chk.ExitCode -ne 0) { throw "STEP 'key': the key text is not a usable private key:`n$($chk.Err)" }
        $reach = $false
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $t = $c.ConnectAsync($SshHost, $Port)
            $reach = $t.Wait(3000) -and $c.Connected
            $c.Close()
        } catch { }
        if (-not $reach) { throw "STEP 'key': ${SshHost}:$Port is not reachable (start the container first: docker compose up -d)" }
    }

    # ---- 2. compile here
    $Raw = Join-Path $LogDir "$Name.raw.vvp"
    $Vvp = Join-Path $LogDir "$Name.vvp"
    Step '2 compile' {
        $ver = (& $IvPath -V 2>&1 | Select-Object -First 1) | Out-String
        if ($ver -notmatch 'version 13\.0') { throw "STEP 'compile': local iverilog is not 13.0: $ver" }
        Write-Host ("local " + $ver.Trim())
        Push-Location $ScriptDir
        try {
            $null = Invoke-Native -Step 'iverilog' -Exe $IvPath -Arguments @('-o', "logs/$Name.raw.vvp", "$Name.v")
        } finally { Pop-Location }
        Convert-Vvp $Raw $Vvp
        $hits = Find-LocalPaths $Vvp
        if ($hits.Count -gt 0) { throw "STEP 'compile': local paths remain in the .vvp (patterns: $($hits -join ', '))" }
        Remove-Item $Raw -Force
    }

    # ---- 3. local reference
    $ref = $null
    Step '3 local run' {
        $r = Invoke-Native -Step 'local vvp' -Exe $VvpPath -Arguments @('-n', "logs/$Name.vvp")
        $script:ref = ($r.Out + $r.Err)
        [System.IO.File]::WriteAllText((Join-Path $LogDir "$Name.local.log"), $script:ref)
    }

    # ---- 4. copy and run over SSH
    $Run = "$Name-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $RunDir = "/work/$Run"
    Step '4 ssh run' {
        $null = Ssh 'ssh mkdir' "mkdir -p $RunDir"
        $null = Scp 'scp upload' "logs/$Name.vvp" "${Remote}:$RunDir/$Name.vvp"
        $null = Ssh 'ssh vvp' "cd $RunDir && vvp -n $Name.vvp > $Name.log 2>&1"
        $null = Scp 'scp log' "${Remote}:$RunDir/$Name.log" "logs/$Name.log"
    }

    # ---- 5. compare
    Step '5 compare' {
        $remoteTxt = [System.IO.File]::ReadAllText((Join-Path $LogDir "$Name.log"))
        if ($remoteTxt -notmatch 'PASS: hello') { throw "STEP 'compare': PASS: hello missing in the remote log:`n$remoteTxt" }
        $norm = { param($t) ($t -split "`r?`n") | Where-Object { $_ -ne '' } | ForEach-Object { if ($_ -match '(\$finish called at.*)$') { $Matches[1] } else { $_ } } }
        $a = @(& $norm $script:ref)
        $b = @(& $norm $remoteTxt)
        $diff = Compare-Object -ReferenceObject $a -DifferenceObject $b -SyncWindow 0
        Write-Host '--- local reference'; $script:ref.TrimEnd() | Write-Host
        Write-Host '--- remote log'; $remoteTxt.TrimEnd() | Write-Host
        if ($diff) {
            Write-Host 'Differing lines (<= local, => remote):'
            $diff | ForEach-Object { Write-Host ("  {0} {1}" -f $_.SideIndicator, $_.InputObject) }
            throw "STEP 'compare': remote output differs from the local reference"
        }
    }

    # ---- 6. clean up
    Step '6 clean up' {
        $null = Ssh 'ssh cleanup' "rm -rf $RunDir"
    }

    Write-Host 'REMOTE TEST OK'
    foreach ($k in $Timings.Keys) { Write-Host ("  {0,-12} {1} s" -f $k, $Timings[$k]) }
    $rc = 0
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    $rc = 1
}
finally {
    # The key and known_hosts of this run are removed in every case.
    if ($TmpDir -and (Test-Path $TmpDir)) { Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue }
}
exit $rc
