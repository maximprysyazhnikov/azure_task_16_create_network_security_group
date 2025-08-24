# task.ps1 — Create & attach NSGs for todoapp VNet (robust discovery)
# Run in PowerShell 7 with Az module and logged in via Connect-AzAccount
param(
  [string]$ResourceGroupName = "mate-resources",
  [string]$VNetName
)
$ErrorActionPreference = 'Stop'

# --- Ensure we are logged in and have a subscription selected ---
try { (Get-AzContext | Out-Null) } catch { Connect-AzAccount | Out-Null }

# --- Helper: pretty list VNets if nothing found ---
function Show-Vnets {
  $list = Get-AzVirtualNetwork | Select-Object `
    Name, ResourceGroupName, Location, @{N='Subnets';E={$_.Subnets.Name -join ','}}
  Write-Host "`nVNets in current subscription:" -ForegroundColor Yellow
  $list | Format-Table -AutoSize | Out-String | Write-Host
}

# --- Locate target VNet ---
$vnet = $null
if ($VNetName) {
  if ($ResourceGroupName) {
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
  }
  if (-not $vnet) {
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ErrorAction SilentlyContinue
  }
} else {
  # Heuristic: find VNet that has subnets webservers/database/management
  $vnetsScope = if ($ResourceGroupName) {
    Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
  } else {
    Get-AzVirtualNetwork
  }

  $vnet = $vnetsScope | Where-Object {
    ($_.Subnets.Name -contains 'webservers') -and
    ($_.Subnets.Name -contains 'database')   -and
    ($_.Subnets.Name -contains 'management')
  } | Select-Object -First 1
}

if (-not $vnet) {
  Write-Host "Could not auto-detect the VNet." -ForegroundColor Red
  Show-Vnets
  throw "VNet not found. Pass explicit parameters, e.g.:
    pwsh ./task.ps1 -ResourceGroupName 'mate-resources' -VNetName '<your-vnet-name>'"
}

$rg       = $vnet.ResourceGroupName
$location = $vnet.Location
Write-Host "Using VNet '$($vnet.Name)' in RG '$rg' ($location)" -ForegroundColor Cyan

# --- Rules & NSG creation helpers ---
function New-Rule-VNetInbound {
  param([int]$Priority = 100)
  New-AzNetworkSecurityRuleConfig `
    -Name "Allow-VNet-Inbound" `
    -Description "Allow from VirtualNetwork" `
    -Access Allow -Protocol * -Direction Inbound -Priority $Priority `
    -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange *
}

function Ensure-Nsg {
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [ValidateSet('web','mgmt','db')] [string] $Kind
  )
  $existing = Get-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "NSG '$Name' exists — ensuring required rules..." -ForegroundColor DarkCyan
    $has = { param($n,$r) ($n.SecurityRules | Where-Object Name -eq $r) -ne $null }

    if (-not (& $has $existing 'Allow-VNet-Inbound')) {
      Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $existing -Name 'Allow-VNet-Inbound' `
        -Description "Allow from VirtualNetwork" -Access Allow -Protocol * -Direction Inbound -Priority 100 `
        -SourceAddressPrefix VirtualNetwork -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange *
    }
    if ($Kind -eq 'web') {
      if (-not (& $has $existing 'Allow-HTTP-From-Internet')) {
        Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $existing -Name 'Allow-HTTP-From-Internet' `
          -Description "Allow HTTP from Internet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
          -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80
      }
      if (-not (& $has $existing 'Allow-HTTPS-From-Internet')) {
        Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $existing -Name 'Allow-HTTPS-From-Internet' `
          -Description "Allow HTTPS from Internet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 201 `
          -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443
      }
    }
    if ($Kind -eq 'mgmt') {
      if (-not (& $has $existing 'Allow-SSH-From-Internet')) {
        Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $existing -Name 'Allow-SSH-From-Internet' `
          -Description "Allow SSH from Internet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
          -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
      }
    }

    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $existing | Out-Null
    return (Get-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $rg)
  }

  # fresh create
  $rules = @()
  $rules += New-Rule-VNetInbound -Priority 100
  switch ($Kind) {
    'web'  {
      $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-HTTP-From-Internet' `
        -Description "Allow HTTP from Internet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
        -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80
      $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-HTTPS-From-Internet' `
        -Description "Allow HTTPS from Internet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 201 `
        -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443
    }
    'mgmt' {
      $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-SSH-From-Internet' `
        -Description "Allow SSH from Internet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
        -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
    }
    'db'   { } # only VNet inbound (no Internet)
  }

  New-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $rg -Location $location -SecurityRules $rules
}

$nsgWeb  = Ensure-Nsg -Name 'webservers'  -Kind 'web'
$nsgDb   = Ensure-Nsg -Name 'database'    -Kind 'db'
$nsgMgmt = Ensure-Nsg -Name 'management'  -Kind 'mgmt'

function Get-Subnet-Addr {
  param($Subnet)
  if ($Subnet.AddressPrefix)  { return $Subnet.AddressPrefix }
  if ($Subnet.AddressPrefixes){ return $Subnet.AddressPrefixes }
  throw "Subnet '$($Subnet.Name)' has no AddressPrefix(es)"
}

function Attach-SubnetNsg {
  param([string]$SubnetName, [Microsoft.Azure.Commands.Network.Models.PSNetworkSecurityGroup]$Nsg)
  $sn = $vnet.Subnets | Where-Object Name -eq $SubnetName
  if (-not $sn) { throw "Subnet '$SubnetName' not found in VNet '$($vnet.Name)'" }
  $addr = Get-Subnet-Addr $sn
  Set-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $addr -NetworkSecurityGroup $Nsg | Out-Null
  Write-Host "  -> attached NSG '$($Nsg.Name)' to subnet '$SubnetName'"
}

Write-Host "Attaching NSGs to subnets..."
Attach-SubnetNsg -SubnetName 'webservers' -Nsg $nsgWeb
Attach-SubnetNsg -SubnetName 'database'   -Nsg $nsgDb
Attach-SubnetNsg -SubnetName 'management' -Nsg $nsgMgmt

# persist
$vnet | Set-AzVirtualNetwork | Out-Null
Write-Host "Done. NSGs are created/updated and associated."
