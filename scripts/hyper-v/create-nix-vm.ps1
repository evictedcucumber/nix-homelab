#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates or updates the NixOS tcyclops (test), dcyclops (dev) or vm-dev (desktop)
    Hyper-V VM idempotently, or destroys an ephemeral one.

.DESCRIPTION
    Manages Generation 2 Hyper-V VMs running NixOS, selected with -VM. They are
    separate from the Debian tcyclops and dcyclops VMs, which have different
    Hyper-V names, switches and subnets. Build the ISO with `just iso <vm> <dir>`.

    Each VM gets its own internal virtual switch and subnet; the host holds
    the .1 address of each subnet as the guest gateway:

      VM        Switch          Host/gateway IP   Subnet
      tcyclops  NixHomelab      172.16.0.1        172.16.0.0/24
      dcyclops  NixHomelabDev   172.16.1.1        172.16.1.0/24
      vm-dev    NixHomelabDev   172.16.1.1        172.16.1.0/24

    Both subnets use this lab's own NAT, "NixHomelabNAT", with prefix
    172.16.0.0/16, which this script creates if it is missing. It never changes
    or removes a NAT, and stops if an existing one conflicts with that prefix.
    Microsoft supports only one NAT per host, so it warns if another one exists,
    such as the Debian lab's "HomelabNAT".

      tcyclops  Permanent test VM. Created once and reconciled on re-runs.
      dcyclops  Ephemeral dev VM. Brought up, used, brought down, and rebuilt
                from scratch with -Rebuild (e.g. -VM dcyclops -Rebuild -Start).
      vm-dev    Ephemeral desktop VM for testing services on dcyclops's network.

    tcyclops and dcyclops get a 512 GB system disk and two 8 TB data disks,
    which the guest mirrors, and vm-dev a 16 GB disk. All are dynamic VHDX, so
    each file on E: only grows with the data the guest writes. Data disks
    missing from an existing VM are added, but an existing system disk is never
    resized, and any other disk attached to the VM stops the script.

    Creates the VM if it does not exist, or reconciles its configuration if it
    already exists. Most settings (vCPU count, nested virtualization, static
    memory, firmware, TPM) can only be changed while the VM is in the Off
    state. If the VM is running the script stops with a clear message; pass
    -Force to have it stopped automatically.

    The install ISO is only attached, and the boot order only changed, when
    the VM is first created, or when -Reinstall or -Rebuild is given. This
    prevents a re-run from silently re-triggering the unattended installer
    (which would wipe the disk) on an already-provisioned VM.

    The ISO boots into the installer with no keypress, so a fresh VM boots
    disk first: the blank disk falls through to the DVD for the install, and
    the installed disk boots itself afterwards instead of reinstalling.

    -Rebuild (ephemeral VMs only) turns the VM off, removes it together with
    its checkpoints and its VHD directory, then creates it again from scratch
    with the ISO attached and a fresh "pre-os-install" checkpoint. It is
    refused for permanent VMs such as tcyclops; use -Reinstall there.

    -Destroy (ephemeral VMs only) does the same removal and stops there. It
    leaves the switch and NAT, which other VMs share.

    -Compact shuts the VM down, compacts each attached VHDX so it gives back
    the space the guest has trimmed, and starts the VM again if it was running.

.PARAMETER VM
    Which VM to manage: tcyclops (permanent test VM), dcyclops (ephemeral dev
    VM) or vm-dev (ephemeral desktop VM). Per-VM name and sizing live in the
    Desired Configuration section.

.PARAMETER IsoPath
    Path to the autoinstall ISO to mount in the VM's DVD drive. Required unless
    -Destroy is given.

.PARAMETER Force
    Stop the VM if it is running so offline-only settings can be applied.

.PARAMETER Reinstall
    Re-attach the ISO and set the DVD as first boot device even on an existing
    VM. WARNING: on next boot this re-runs the unattended installer.

.PARAMETER Rebuild
    Destroy and recreate the VM from scratch: stop it, remove the VM, delete
    its VHD directory (including checkpoint files), then run the normal create
    path. Only allowed for ephemeral VMs (dcyclops). WARNING: all VM data is
    lost.

.PARAMETER Destroy
    Turn the VM off, remove it, and delete its folder including every VHD and
    checkpoint file. Only allowed for ephemeral VMs. WARNING: all VM data is
    lost.

.PARAMETER Compact
    Shut the VM down, compact its attached disks, and start it again if it
    was running. Run fstrim in the guest first, or there is little to reclaim.
    A checkpoint's parent disks are left alone, since changing one breaks the
    chain.

.PARAMETER Start
    Start the VM after it has been configured, if it is not already running.

.EXAMPLE
    .\create-nix-vm.ps1 -VM tcyclops -IsoPath E:\isos\tcyclops-nix-auto.iso

    First create of the permanent test VM (or reconcile an existing one).

.EXAMPLE
    .\create-nix-vm.ps1 -VM dcyclops -IsoPath E:\isos\dcyclops-nix-auto.iso -Rebuild -Start

    Throw away dcyclops (if present), recreate it from scratch, and boot it
    into the unattended installer.

.EXAMPLE
    .\create-nix-vm.ps1 -VM vm-dev -Destroy

    Remove the desktop VM and everything stored for it.

.EXAMPLE
    .\create-nix-vm.ps1 -VM tcyclops -Compact

    Shrink the test VM's disk files after trimming in the guest.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('tcyclops', 'dcyclops', 'vm-dev')]
    [string]$VM,

    [string]$IsoPath,

    [switch]$Force,

    [switch]$Reinstall,

    [switch]$Rebuild,

    [switch]$Destroy,

    [switch]$Compact,

    [switch]$Start
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Desired Configuration
# ---------------------------------------------------------------------

# Per-VM settings. Ephemeral VMs may be destroyed and recreated with -Rebuild.
$VMConfigs = @{
    tcyclops = @{
        Name          = "[nix] tcyclops.homelab.zezura.cc"
        MemoryStartup = 4GB
        CPUCount      = 2
        VHDSize       = 512GB
        DataVHDSize   = 8TB
        DataVHDCount  = 2
        Ephemeral     = $false
        SwitchName    = "NixHomelab"
        HostIPAddress = "172.16.0.1"
        Subnet        = "172.16.0.0/24"
    }
    dcyclops = @{
        Name          = "[nix] dcyclops.homelab.zezura.cc"
        MemoryStartup = 4GB
        CPUCount      = 2
        VHDSize       = 512GB
        DataVHDSize   = 8TB
        DataVHDCount  = 2
        Ephemeral     = $true
        SwitchName    = "NixHomelabDev"
        HostIPAddress = "172.16.1.1"
        Subnet        = "172.16.1.0/24"
    }
    "vm-dev" = @{
        Name          = "[nix] vm-dev"
        MemoryStartup = 4GB
        CPUCount      = 2
        VHDSize       = 16GB
        Ephemeral     = $true
        SwitchName    = "NixHomelabDev"
        HostIPAddress = "172.16.1.1"
        Subnet        = "172.16.1.0/24"
    }
}

$VMConfig = $VMConfigs[$VM]

$Name = $VMConfig.Name

# PowerShell reads [ and ] as wildcards, so the VM is always found by exact name with
# Get-LabVM and passed as an object, and its folder and disk are named without them.
$StorageName = $Name -replace '[\[\]]', ''

function Get-LabVM
{
    Get-VM | Where-Object { $_.Name -eq $Name }
}

# A checkpoint points the drive at an .avhdx, so drives are matched by the VHD at the
# bottom of its chain.
function Get-BaseVhdPath([string]$Path)
{
    $vhd = Get-VHD -Path $Path
    while ($vhd.ParentPath) { $vhd = Get-VHD -Path $vhd.ParentPath }
    $vhd.Path
}

function Get-LabDiskDrive([string]$BaseVhdPath)
{
    Get-VMHardDiskDrive -VM (Get-LabVM) -ErrorAction SilentlyContinue |
        Where-Object { (Get-BaseVhdPath $_.Path) -eq $BaseVhdPath } |
        Select-Object -First 1
}

$Ephemeral = $VMConfig.Ephemeral

$Generation = 2

$MemoryStartup = $VMConfig.MemoryStartup
$CPUCount = $VMConfig.CPUCount

$SwitchName = $VMConfig.SwitchName
$HostIPAddress = $VMConfig.HostIPAddress
$PrefixLength = 24
$Subnet = $VMConfig.Subnet

# Both switches share this lab's own NAT. Its 172.16.0.0/16 prefix contains
# 172.16.0.0/24 (tcyclops) and 172.16.1.0/24 (dcyclops).
$NatName = "NixHomelabNAT"
$NatPrefix = "172.16.0.0/16"
$LabAdapterAliases = @("vEthernet (NixHomelab)", "vEthernet (NixHomelabDev)")

$VMPath = "E:\Hyper-V VMs"
$VMRoot = [System.IO.Path]::GetFullPath((Join-Path $VMPath $StorageName))
$VHDDirectory = Join-Path $VMRoot "Virtual Hard Disks"
$VHDPath = Join-Path $VHDDirectory "$StorageName.vhdx"
$VHDSize = $VMConfig.VHDSize
$VHDSizeGB = [int]($VHDSize / 1GB)

# Optional data disks, attached in order so the guest sees them as /dev/sdb, /dev/sdc, ...
$DataVHDSize = $VMConfig.DataVHDSize
$DataVHDPaths = @(
    if ($VMConfig.DataVHDCount)
    {
        1..$VMConfig.DataVHDCount | ForEach-Object { Join-Path $VHDDirectory "$StorageName-data$_.vhdx" }
    }
)

$EnableTPM = $true

# ---------------------------------------------------------------------
# Removal  (ephemeral VMs only)
# ---------------------------------------------------------------------

function Remove-LabVM
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $existingVm = Get-LabVM

    if ($existingVm)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Turn off and remove VM"))
        {
            if ($existingVm.State -ne 'Off')
            {
                Write-Host "Turning off VM '$Name'..." -ForegroundColor Cyan
                Stop-VM -VM (Get-LabVM) -TurnOff -Force -Confirm:$false
            }

            Write-Host "Removing VM '$Name'..." -ForegroundColor Cyan
            Remove-VM -VM (Get-LabVM) -Force -Confirm:$false
        }
    }
    else
    {
        Write-Host "VM '$Name' does not exist; nothing to remove." -ForegroundColor Yellow
    }

    # Delete leftover storage (VHD, .avhdx checkpoint files). Never touch
    # anything outside $VMPath.
    $vmPathFull = [System.IO.Path]::GetFullPath($VMPath).TrimEnd('\', '/')

    if ([string]::IsNullOrWhiteSpace($Name) -or -not $VMRoot.StartsWith($vmPathFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "Refusing to delete '$VMRoot': it is not inside '$vmPathFull'."
    }

    if (Test-Path -LiteralPath $VMRoot)
    {
        if ($PSCmdlet.ShouldProcess($VMRoot, "Delete VM storage (VHDs and checkpoint files)"))
        {
            Write-Host "Deleting '$VMRoot'..." -ForegroundColor Cyan
            Remove-Item -LiteralPath $VMRoot -Recurse -Force
        }
    }
}

if (($Rebuild -or $Destroy) -and -not $Ephemeral)
{
    throw "-Rebuild and -Destroy are refused for permanent VM '$VM'. Use -Reinstall to re-arm the installer instead."
}

if ($Destroy)
{
    Remove-LabVM
    return
}

if ($Compact)
{
    $existingVm = Get-LabVM
    if (-not $existingVm)
    {
        throw "VM '$Name' does not exist."
    }

    if ($existingVm.State -notin 'Running', 'Off')
    {
        throw "VM '$Name' is $($existingVm.State); start or turn it off first."
    }

    $wasRunning = $existingVm.State -eq 'Running'
    if ($wasRunning)
    {
        Write-Host "Shutting down VM '$Name'..." -ForegroundColor Cyan
        Stop-VM -VM $existingVm -Force -Confirm:$false
    }

    try
    {
        foreach ($path in Get-VMHardDiskDrive -VM (Get-LabVM) | ForEach-Object { $_.Path })
        {
            $before = (Get-Item -LiteralPath $path).Length
            Write-Host "Compacting '$path'..." -ForegroundColor Cyan
            Optimize-VHD -Path $path -Mode Full
            $after = (Get-Item -LiteralPath $path).Length
            Write-Host ("  {0:N1} GB -> {1:N1} GB" -f ($before / 1GB), ($after / 1GB))
        }
    }
    finally
    {
        if ($wasRunning)
        {
            Write-Host "Starting VM '$Name'..." -ForegroundColor Cyan
            Start-VM -VM (Get-LabVM)
        }
    }
    return
}

# ---------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------

if (-not $IsoPath)
{
    throw "-IsoPath is required unless -Destroy or -Compact is given."
}

# Resolve the ISO to an absolute path up front: Hyper-V cmdlets and the VMMS
# service do not share this process's working directory, and $dvd.Path
# comparisons later assume an absolute path.
try
{
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
}
catch
{
    throw "ISO not found: $IsoPath"
}

function Test-CidrOverlap
{
    param(
        [Parameter(Mandatory)][string]$CidrA,
        [Parameter(Mandatory)][string]$CidrB
    )

    $ranges = foreach ($cidr in $CidrA, $CidrB)
    {
        $addr, $len = $cidr -split '/'
        [uint64]$start = 0
        foreach ($byte in ([System.Net.IPAddress]::Parse($addr)).GetAddressBytes())
        {
            $start = $start * 256 + $byte
        }
        [uint64]$size = [math]::Pow(2, 32 - [int]$len)
        $start -= $start % $size
        , @($start, ($start + $size - 1))
    }

    return $ranges[0][0] -le $ranges[1][1] -and $ranges[1][0] -le $ranges[0][1]
}

function Assert-NatAvailable
{
    foreach ($nat in @(Get-NetNat -ErrorAction SilentlyContinue))
    {
        $prefix = $nat.InternalIPInterfaceAddressPrefix

        if ($nat.Name -eq $NatName)
        {
            if ($prefix -ne $NatPrefix)
            {
                throw "NAT '$NatName' is on $prefix, not $NatPrefix. Remove it and run this again; this script will not change a NAT."
            }
        }
        elseif ($prefix -and $prefix -notmatch ':' -and (Test-CidrOverlap $prefix $NatPrefix))
        {
            throw "NAT '$($nat.Name)' ($prefix) overlaps this lab's range $NatPrefix. Remove or renumber it first; this script will not change it."
        }
        else
        {
            Write-Warning "Another NAT '$($nat.Name)' ($prefix) exists. Microsoft supports only one NAT per host, so running both is unsupported."
        }
    }

    # Windows picks the WSL and Default Switch subnets itself, from this same private range.
    $clash = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notin $LabAdapterAliases -and (Test-CidrOverlap "$($_.IPAddress)/32" $NatPrefix) } |
        Select-Object -First 1

    if ($clash)
    {
        throw "Adapter '$($clash.InterfaceAlias)' has address $($clash.IPAddress), inside this lab's range $NatPrefix."
    }
}

function Assert-Prerequisite
{
    if (-not (Get-Module -ListAvailable Hyper-V))
    {
        throw "Hyper-V PowerShell module is not installed."
    }

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf))
    {
        throw "ISO is not a file: $IsoPath"
    }

    $vmDriveRoot = [System.IO.Path]::GetPathRoot($VMPath)
    if ($vmDriveRoot -and -not (Test-Path -LiteralPath $vmDriveRoot))
    {
        throw "VM storage location is not available: $vmDriveRoot (from `$VMPath = $VMPath)"
    }

    Assert-NatAvailable
}

Assert-Prerequisite

# ---------------------------------------------------------------------
# Network Switch Setup
# ---------------------------------------------------------------------

function Initialize-NetworkSwitch
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue

    if (-not $switch)
    {
        if ($PSCmdlet.ShouldProcess($SwitchName, "Create Internal Virtual Switch"))
        {
            Write-Host "Creating Virtual Switch '$SwitchName'..." -ForegroundColor Cyan
            New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        }
    }
    else
    {
        Write-Host "Virtual switch '$SwitchName' already exists." -ForegroundColor Yellow
    }

    $adapterAlias = "vEthernet ($SwitchName)"

    # Wait for adapter
    $adapter = $null
    for ($i = 0; $i -lt 20; $i++)
    {
        $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
        if ($adapter) { break }
        Start-Sleep -Seconds 1
    }

    if (-not $adapter)
    {
        Write-Warning "Adapter '$adapterAlias' did not appear after 20s; skipping host gateway IP configuration."
    }
    else
    {
        $ip = Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $HostIPAddress }

        if (-not $ip)
        {
            if ($PSCmdlet.ShouldProcess($adapterAlias, "Assign Gateway IP $HostIPAddress/$PrefixLength"))
            {
                Write-Host "Assigning IP $HostIPAddress to $adapterAlias (subnet $Subnet)..." -ForegroundColor Cyan

                Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike "169.254.*" } |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                $newIp = New-NetIPAddress `
                    -InterfaceAlias $adapterAlias `
                    -IPAddress $HostIPAddress `
                    -PrefixLength $PrefixLength `
                    -ErrorAction SilentlyContinue

                if (-not $newIp)
                {
                    Write-Warning "Failed to assign $HostIPAddress/$PrefixLength to '$adapterAlias'. VM guests will have no gateway."
                }
            }
        }
    }
}

function Initialize-LabNat
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)
    {
        Write-Host "NAT '$NatName' ($NatPrefix) already exists." -ForegroundColor Yellow
        return
    }

    if ($PSCmdlet.ShouldProcess($NatName, "Create NAT ($NatPrefix)"))
    {
        Write-Host "Creating NAT '$NatName' ($NatPrefix)..." -ForegroundColor Cyan
        try
        {
            New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatPrefix -ErrorAction Stop | Out-Null
        }
        catch
        {
            throw "Windows refused to create NAT '$NatName' ($NatPrefix): $($_.Exception.Message) Microsoft supports only one NAT per host, so another NAT may be blocking it."
        }
    }
}

Initialize-NetworkSwitch
Initialize-LabNat

# ---------------------------------------------------------------------
# Rebuild: tear down so the create path starts fresh
# ---------------------------------------------------------------------

if ($Rebuild)
{
    Remove-LabVM
}

# ---------------------------------------------------------------------
# Directory Setup
# ---------------------------------------------------------------------

if (-not (Test-Path $VMPath))
{
    if ($PSCmdlet.ShouldProcess($VMPath, "Create VM directory"))
    {
        New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
    }
}

if (-not (Test-Path $VHDDirectory))
{
    if ($PSCmdlet.ShouldProcess($VHDDirectory, "Create VHD directory"))
    {
        New-Item -ItemType Directory -Path $VHDDirectory -Force | Out-Null
    }
}

# ---------------------------------------------------------------------
# VM Creation / Existence Check
# ---------------------------------------------------------------------

$currentVm = Get-LabVM
$vmIsNew = $false

if (-not $currentVm)
{
    foreach ($path in @($VHDPath) + $DataVHDPaths)
    {
        if (Test-Path $path)
        {
            throw "VHD already exists but VM does not: $path"
        }
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create ${VHDSizeGB}GB Dynamic VHD and Generation $Generation VM"))
    {
        Write-Host "Creating $VHDSizeGB GB Dynamic VHD..." -ForegroundColor Cyan
        New-VHD -Path $VHDPath -SizeBytes $VHDSize -Dynamic | Out-Null

        Write-Host "Creating Generation $Generation VM '$Name'..." -ForegroundColor Cyan

        # New-VM adds a folder named after the VM under -Path for its configuration.
        $currentVm = New-VM `
            -Name $Name `
            -Generation $Generation `
            -Path $VMRoot `
            -MemoryStartupBytes $MemoryStartup `
            -VHDPath $VHDPath `
            -SwitchName $SwitchName

        Set-VM `
            -VM (Get-LabVM) `
            -SnapshotFileLocation $VMRoot `
            -SmartPagingFilePath $VMRoot

        $vmIsNew = $true
    }
}
else
{
    if ($currentVm.Generation -ne $Generation)
    {
        throw "VM '$Name' already exists but is Generation $($currentVm.Generation). This script requires a Generation $Generation VM."
    }

    Write-Host "VM '$Name' already exists (Generation $Generation). Ensuring configuration..." -ForegroundColor Yellow
}

# Verify VM exists before proceeding with configuration (e.g. if skipped in WhatIf mode)
$targetVm = Get-LabVM

if (-not $targetVm)
{
    Write-Host "VM '$Name' does not exist (WhatIf mode or creation skipped). Skipping configuration steps." -ForegroundColor Yellow
    return
}

# Every file the VM uses must be under its own folder, including on a VM that
# already existed. Move-VMStorage can move one that isn't.
$misplaced = @(
    $targetVm.ConfigurationLocation
    $targetVm.SnapshotFileLocation
    $targetVm.SmartPagingFilePath
    Get-VMHardDiskDrive -VM (Get-LabVM) | ForEach-Object { $_.Path }
) | Where-Object {
    $_ -and -not ([System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\').StartsWith($VMRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

if ($misplaced)
{
    throw "VM '$Name' has files outside '$VMRoot': $($misplaced -join ', ')"
}

# ---------------------------------------------------------------------
# Power State Guard
# ---------------------------------------------------------------------
# Almost every Set-* below requires the VM to be Off. Fail fast (or stop the
# VM with -Force) rather than erroring halfway through reconciliation.

if ($targetVm.State -ne 'Off')
{
    # -Rebuild always yields a new VM, so no -Force is needed (this branch is
    # only reachable under -WhatIf, where the old VM was not really removed).
    if ($Force -or $Rebuild)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Stop VM (currently $($targetVm.State)) to apply offline-only configuration"))
        {
            Write-Host "Stopping VM '$Name'..." -ForegroundColor Cyan
            Stop-VM -VM (Get-LabVM) -TurnOff -Force -Confirm:$false
            $targetVm = Get-LabVM
        }
    }
    else
    {
        throw "VM '$Name' is $($targetVm.State). Stop it first, or re-run with -Force to stop it automatically."
    }
}

# ---------------------------------------------------------------------
# Disks  (dynamic VHDX: they only take the space the guest has written)
# ---------------------------------------------------------------------

$systemVhd = Get-VHD -Path $VHDPath -ErrorAction SilentlyContinue

if ($systemVhd -and $systemVhd.Size -lt $VHDSize)
{
    Write-Host "System disk is $([int]($systemVhd.Size / 1GB)) GB, not $VHDSizeGB GB. It is never resized here; recreate the VM to get the new size." -ForegroundColor Yellow
}

# The guest finds its disks by order, so an extra one, such as an older data disk, would
# shift them.
$expectedVhds = @($VHDPath) + $DataVHDPaths
$unexpected = @(Get-VMHardDiskDrive -VM (Get-LabVM) |
        Where-Object { $expectedVhds -notcontains (Get-BaseVhdPath $_.Path) } |
        ForEach-Object { $_.Path })

if ($unexpected)
{
    throw "VM '$Name' has disks this script doesn't manage: $($unexpected -join ', '). Remove them first, or use -Rebuild."
}

foreach ($dataVhdPath in $DataVHDPaths)
{
    if (-not (Get-LabDiskDrive $dataVhdPath))
    {
        $DataVHDSizeGB = [int]($DataVHDSize / 1GB)

        if ($PSCmdlet.ShouldProcess($Name, "Create and attach ${DataVHDSizeGB}GB Dynamic data VHD '$dataVhdPath'"))
        {
            if (-not (Test-Path $dataVhdPath))
            {
                Write-Host "Creating $DataVHDSizeGB GB Dynamic data VHD..." -ForegroundColor Cyan
                New-VHD -Path $dataVhdPath -SizeBytes $DataVHDSize -Dynamic | Out-Null
            }

            Add-VMHardDiskDrive -VM (Get-LabVM) -ControllerType SCSI -Path $dataVhdPath

            if (-not ($vmIsNew -or $Rebuild -or $Reinstall))
            {
                Write-Host "Data disk added to an installed VM. It stays blank until the VM is reinstalled." -ForegroundColor Yellow
            }
        }
    }
}

# ---------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Name, "Configure Memory ($($MemoryStartup / 1GB) GB Static)"))
{
    Set-VMMemory `
        -VM (Get-LabVM) `
        -DynamicMemoryEnabled $false `
        -StartupBytes $MemoryStartup
}

# ---------------------------------------------------------------------
# CPU & Nested Virtualization
# ---------------------------------------------------------------------

$proc = Get-VMProcessor -VM (Get-LabVM) -ErrorAction SilentlyContinue

if (-not $proc -or $proc.Count -ne $CPUCount -or -not $proc.ExposeVirtualizationExtensions)
{
    if ($PSCmdlet.ShouldProcess($Name, "Configure CPU ($CPUCount vCPUs, Enable Nested Virtualization)"))
    {
        Set-VMProcessor `
            -VM (Get-LabVM) `
            -Count $CPUCount `
            -ExposeVirtualizationExtensions $true
    }
}

# ---------------------------------------------------------------------
# VM Settings & Checkpoints
# ---------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Name, "Configure VM options & disable automatic checkpoints"))
{
    Set-VM `
        -VM (Get-LabVM) `
        -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction StartIfRunning `
        -AutomaticStopAction ShutDown `
        -CheckpointType Standard
}

# ---------------------------------------------------------------------
# Guest Integration Services
# ---------------------------------------------------------------------

$disabledServices = Get-VMIntegrationService -VM (Get-LabVM) -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled }

if ($disabledServices)
{
    foreach ($service in $disabledServices)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Enable Integration Service '$($service.Name)'"))
        {
            Enable-VMIntegrationService -VM (Get-LabVM) -Name $service.Name
        }
    }
}

# ---------------------------------------------------------------------
# DVD / ISO & Boot Order  (first-create, -Rebuild or -Reinstall only)
# ---------------------------------------------------------------------

$applyIso = $vmIsNew -or $Reinstall -or $Rebuild

if ($applyIso)
{
    $dvd = Get-VMDvdDrive -VM (Get-LabVM) -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $dvd)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Add DVD drive with ISO '$IsoPath'"))
        {
            $dvd = Add-VMDvdDrive -VM (Get-LabVM) -Path $IsoPath -Passthru
        }
    }
    elseif ($dvd.Path -ne $IsoPath)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Set DVD drive ISO to '$IsoPath'"))
        {
            Set-VMDvdDrive `
                -VMDvdDrive $dvd `
                -Path $IsoPath
        }
    }

    $dvdDrive = Get-VMDvdDrive -VM (Get-LabVM) -ErrorAction SilentlyContinue | Select-Object -First 1
    $diskDrive = Get-LabDiskDrive $VHDPath

    # The ISO boots straight into the unattended installer, and Hyper-V
    # ignores the installer's eject, so a DVD-first VM would reinstall on
    # every boot. A blank disk (new VM or -Rebuild) is therefore put first:
    # it fails to boot and falls through to the DVD once, then boots itself
    # after install. -Reinstall must boot the DVD over an existing OS, so it
    # goes first there; the installed systemd-boot then registers its own UEFI
    # entry ahead of it, so the installed system boots next time.
    if ($Reinstall -and -not ($vmIsNew -or $Rebuild))
    {
        if ($dvdDrive -and $PSCmdlet.ShouldProcess($Name, "Set first boot device to DVD drive"))
        {
            Set-VMFirmware -VM (Get-LabVM) -FirstBootDevice $dvdDrive
        }
    }
    elseif ($dvdDrive -and $diskDrive)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Set boot order: hard disk, DVD drive, then the rest"))
        {
            $rest = @((Get-VMFirmware -VM (Get-LabVM)).BootOrder | Where-Object {
                    $_.Device -and $_.Device.Id -ne $diskDrive.Id -and $_.Device.Id -ne $dvdDrive.Id
                } | ForEach-Object { $_.Device })

            Set-VMFirmware -VM (Get-LabVM) -BootOrder (@($diskDrive, $dvdDrive) + $rest)
        }
    }
}
else
{
    Write-Host "Leaving ISO / boot order untouched (existing VM). Pass -Reinstall to re-arm the installer." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------
# Secure Boot (Always Disabled)
# ---------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Name, "Disable Secure Boot"))
{
    Set-VMFirmware `
        -VM (Get-LabVM) `
        -EnableSecureBoot Off
}

# ---------------------------------------------------------------------
# Virtual TPM
# ---------------------------------------------------------------------

if ($EnableTPM)
{
    $vmSecurity = Get-VMSecurity -VM (Get-LabVM) -ErrorAction SilentlyContinue

    if (-not $vmSecurity -or -not $vmSecurity.TpmEnabled)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Enable Virtual TPM"))
        {
            Write-Host "Enabling Virtual TPM for '$Name'..." -ForegroundColor Cyan
            Set-VMKeyProtector -VM (Get-LabVM) -NewLocalKeyProtector
            Enable-VMTPM -VM (Get-LabVM)
        }
    }
}

# ---------------------------------------------------------------------
# Ensure Correct Switch
# ---------------------------------------------------------------------

$adapter = Get-VMNetworkAdapter -VM (Get-LabVM) -ErrorAction SilentlyContinue | Select-Object -First 1

if ($adapter -and $adapter.SwitchName -ne $SwitchName)
{
    if ($PSCmdlet.ShouldProcess($Name, "Connect network adapter to switch '$SwitchName'"))
    {
        Connect-VMNetworkAdapter `
            -VMNetworkAdapter $adapter `
            -SwitchName $SwitchName
    }
}

# ---------------------------------------------------------------------
# Pre-OS Install Checkpoint  (first-create or -Reinstall only)
# ---------------------------------------------------------------------

if ($applyIso)
{
    $checkpointName = "pre-os-install"
    $snapshot = Get-VMSnapshot -VM (Get-LabVM) -Name $checkpointName -ErrorAction SilentlyContinue

    if (-not $snapshot)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Create checkpoint '$checkpointName'"))
        {
            Write-Host "Creating checkpoint '$checkpointName'..." -ForegroundColor Cyan
            Checkpoint-VM -VM (Get-LabVM) -SnapshotName $checkpointName
        }
    }
    else
    {
        Write-Host "Checkpoint '$checkpointName' already exists." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------
# Verify Required Features
# ---------------------------------------------------------------------

if (-not $WhatIfPreference)
{
    $problems = @(
        if ((Get-LabVM).Generation -ne $Generation) { "not Generation $Generation" }
        if (-not (Get-VMProcessor -VM (Get-LabVM)).ExposeVirtualizationExtensions) { "nested virtualization is off" }
        Get-VMIntegrationService -VM (Get-LabVM) | Where-Object { -not $_.Enabled } | ForEach-Object { "integration service '$($_.Name)' is off" }
    )

    if ($problems)
    {
        throw "VM '$Name' is not configured as required: $($problems -join '; ')"
    }
}

# ---------------------------------------------------------------------
# Summary Output
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host "VM Configuration Summary" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green

Get-LabVM |
    Select-Object `
        Name,
        State,
        Generation,
        ProcessorCount,
        @{Name = "MemoryStartupGB"; Expression = { $_.MemoryStartup / 1GB } },
        AutomaticStartAction,
        AutomaticStopAction,
        AutomaticCheckpointsEnabled,
        CheckpointType,
        ConfigurationLocation,
        SnapshotFileLocation,
        SmartPagingFilePath |
    Format-List

Get-VMProcessor -VM (Get-LabVM) |
    Select-Object Count, ExposeVirtualizationExtensions |
    Format-List

Get-VMSecurity -VM (Get-LabVM) |
    Select-Object TpmEnabled |
    Format-List

Get-VMHardDiskDrive -VM (Get-LabVM) |
    Get-VHD |
    Select-Object Path,
        VhdType,
        @{Name = "SizeGB"; Expression = { [int]($_.Size / 1GB) } },
        @{Name = "UsedGB"; Expression = { [math]::Round($_.FileSize / 1GB, 1) } } |
    Format-Table -AutoSize

Get-VMIntegrationService -VM (Get-LabVM) |
    Select-Object Name, Enabled |
    Format-Table -AutoSize

Get-VMSnapshot -VM (Get-LabVM) |
    Select-Object Name, CreationTime |
    Format-Table -AutoSize

# ---------------------------------------------------------------------
# Start VM
# ---------------------------------------------------------------------

if ($Start)
{
    $startVm = Get-LabVM

    if ($startVm -and $startVm.State -eq 'Running')
    {
        Write-Host "VM '$Name' is already running." -ForegroundColor Yellow
    }
    elseif ($PSCmdlet.ShouldProcess($Name, "Start VM"))
    {
        Write-Host "Starting VM '$Name'..." -ForegroundColor Cyan
        Start-VM -VM (Get-LabVM)
    }
}
