<#
.SYNOPSIS
    Run a script from this folder elevated, for callers that aren't, such as WSL.

.DESCRIPTION
    Shows a UAC prompt, runs the script in its own window, then prints its output
    here and exits non-zero if it failed.

    The script runs from a temporary copy on the Windows disk, which is deleted
    afterwards, because an elevated process may not be able to read a WSL path.

.EXAMPLE
    .\run-elevated.ps1 .\interface-forwarding.ps1 Enable -SkipWsl
#>

param(
    [string]$ScriptPath
)

$ErrorActionPreference = 'Stop'

$runner = @'
param([string]$Script, [string]$Log)

$ErrorActionPreference = 'Stop'

try
{
    & $Script @args *>&1 | Tee-Object -LiteralPath $Log
}
catch
{
    $_ | Out-String | Add-Content -LiteralPath $Log
    exit 1
}
'@

$workDir = Join-Path $env:TEMP "nix-homelab-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $workDir | Out-Null

try
{
    $script = Join-Path $workDir (Split-Path -Leaf $ScriptPath)
    $runnerPath = Join-Path $workDir 'runner.ps1'
    $log = Join-Path $workDir 'output.log'

    Copy-Item -LiteralPath $ScriptPath -Destination $script
    Set-Content -LiteralPath $runnerPath -Value $runner

    $quoted = @($runnerPath, $script, $log) + $args | ForEach-Object {
        if ("$_".StartsWith('-')) { "$_" } else { "`"$_`"" }
    }

    $process = Start-Process powershell.exe -Verb RunAs -PassThru -ArgumentList (
        @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $quoted
    )

    # ExitCode stays empty unless the handle is read while the process is running
    $null = $process.Handle
    $process.WaitForExit()

    if (Test-Path -LiteralPath $log)
    {
        Get-Content -LiteralPath $log
    }

    exit $process.ExitCode
}
finally
{
    Remove-Item -LiteralPath $workDir -Recurse -Force
}
