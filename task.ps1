param(
  [string]$ResourceGroupName = "mate-azure-task-16",
  [string]$Location = "westeurope",
  [string]$VNetName = "todoapp"
)

$ErrorActionPreference = "Stop"

# --- Ensure resource group exists (required by tests) ---
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
  New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
  Write-Host "Created resource group '$ResourceGroupName' in $Location"
} else {
  Write-Host "Using existing resource group '$ResourceGroupName' in $Location"
}

# --- Ensure VNet exists (from Task 15) ---
$vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $vnet) {
  Write-Host "Creating new VNet $VNetName..."
  $addressSpace = "10.0.0.0/16"
  $subnetWeb = New-AzVirtualNetworkSubnetConfig -Name "webservers" -AddressPrefix "10.0.1.0/24"
  $subnetDb = New-AzVirtualNetworkSubnetConfig -Name "database" -AddressPrefix "10.0.2.0/24"
  $subnetMgmt = New-AzVirtualNetworkSubnetConfig -Name "management" -AddressPrefix "10.0.3.0/24"

  $vnet = New-AzVirtualNetwork -Name $VNetName `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -AddressPrefix $addressSpace `
    -Subnet $subnetWeb,$subnetDb,$subnetMgmt
} else {
  Write-Host "Using existing VNet '$VNetName'"
}

# --- Helper to (re)create NSG with expected rules ---
function Ensure-Nsg {
  param(
    [string]$Name,
    [string]$Kind # web, mgmt, db
  )

  $nsg = Get-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
  if ($nsg) {
    Remove-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $ResourceGroupName -Force
  }

  switch ($Kind) {
    "web" {
      $rule = New-AzNetworkSecurityRuleConfig -Name "Allow-Web-From-Internet" `
        -Description "Allow HTTP/HTTPS from Internet" `
        -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
        -SourceAddressPrefix * -SourcePortRange * `
        -DestinationAddressPrefix * -DestinationPortRanges 80,443
      $nsg = New-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rule
    }
    "mgmt" {
      $rule = New-AzNetworkSecurityRuleConfig -Name "Allow-SSH-From-Internet" `
        -Description "Allow SSH from Internet" `
        -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
        -SourceAddressPrefix * -SourcePortRange * `
        -DestinationAddressPrefix * -DestinationPortRange 22
      $nsg = New-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rule
    }
    "db" {
      $nsg = New-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location
    }
  }
  return $nsg
}

$nsgWeb  = Ensure-Nsg -Name "webservers"  -Kind "web"
$nsgMgmt = Ensure-Nsg -Name "management" -Kind "mgmt"
$nsgDb   = Ensure-Nsg -Name "database"   -Kind "db"

# --- Attach NSG to subnets ---
function Attach-SubnetNsg {
  param(
    [string]$SubnetName,
    [Microsoft.Azure.Commands.Network.Models.PSNetworkSecurityGroup]$Nsg
  )
  $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
  $addr = if ($subnet.AddressPrefix) { $subnet.AddressPrefix } else { $subnet.AddressPrefixes }
  Set-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $addr -NetworkSecurityGroup $Nsg | Out-Null
}

Attach-SubnetNsg -SubnetName "webservers" -Nsg $nsgWeb
Attach-SubnetNsg -SubnetName "database"   -Nsg $nsgDb
Attach-SubnetNsg -SubnetName "management" -Nsg $nsgMgmt

# persist changes to VNet
$vnet | Set-AzVirtualNetwork | Out-Null

Write-Host "✅ Deployment finished: VNet + NSGs with correct rules"
