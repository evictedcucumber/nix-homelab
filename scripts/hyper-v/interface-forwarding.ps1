#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enable or disable IPv4 forwarding on the WSL and Hyper-V lab switch interfaces.

.DESCRIPTION
    Enabling lets a WSL2 instance route to Hyper-V VMs on the lab switch(es).
    Disabling turns forwarding off again on the same interfaces.

    The WSL vEthernet interface is recreated every time WSL restarts, which
    resets its forwarding flag, so re-run this after `wsl --shutdown`. The
    forwarding flag on the Hyper-V switch interface persists across reboots.

    The WSL adapter is discovered by pattern rather than hardcoded, so this
    works whether it is named "vEthernet (WSL)" or
    "vEthernet (WSL (Hyper-V firewall))".

.PARAMETER Action
    Enable or Disable.

.PARAMETER SwitchName
    Hyper-V virtual switch names whose host vEthernet interface should have
    forwarding changed. Defaults to 'NixHomelab' (tcyclops) and
    'NixHomelabDev' (dcyclops).

.PARAMETER SkipWsl
    Do not touch the WSL vEthernet interface.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Enable', 'Disable')]
    [string]$Action,

    [string[]]$SwitchName = @('NixHomelab', 'NixHomelabDev'),
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'

$State = if ($Action -eq 'Enable') { 'Enabled' } else { 'Disabled' }

function Set-Forwarding
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)] $Adapter)

    $ifaces = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

    if (-not $ifaces)
    {
        Write-Warning "No IPv4 interface for adapter '$($Adapter.Name)'; skipping."
        return
    }

    foreach ($iface in $ifaces)
    {
        if ($iface.Forwarding -eq $State)
        {
            Write-Host "Forwarding already $($State.ToLower()) on '$($Adapter.Name)'." -ForegroundColor Yellow
            continue
        }

        if ($PSCmdlet.ShouldProcess($Adapter.Name, "$Action IPv4 forwarding"))
        {
            Set-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -Forwarding $State
            Write-Host "$($State) forwarding on '$($Adapter.Name)'." -ForegroundColor Cyan
        }
    }
}

$adapters = [System.Collections.Generic.List[object]]::new()

foreach ($name in $SwitchName)
{
    $alias = "vEthernet ($name)"
    $found = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if ($found)
    {
        $adapters.Add($found)
    }
    else
    {
        Write-Warning "Adapter '$alias' not found (is the '$name' switch created?)."
    }
}

if (-not $SkipWsl)
{
    $wsl = Get-NetAdapter |
        Where-Object { $_.Name -like 'vEthernet (WSL*' -or $_.InterfaceDescription -like '*WSL*' }

    if ($wsl)
    {
        foreach ($w in $wsl) { $adapters.Add($w) }
    }
    else
    {
        Write-Warning "No WSL vEthernet adapter found (is WSL running?)."
    }
}

if ($adapters.Count -eq 0)
{
    throw "No target adapters found; nothing to do."
}

$adapters |
    Sort-Object -Property ifIndex -Unique |
    ForEach-Object { Set-Forwarding -Adapter $_ }
