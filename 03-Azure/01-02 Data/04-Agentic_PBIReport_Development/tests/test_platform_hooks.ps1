$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$lab = Join-Path (Split-Path -Parent $PSScriptRoot) 'labautomation'
$script:passed = 0
$script:diagnosticMessages = [Collections.Generic.List[string]]::new()
function Write-Host { param([object]$Object) $script:diagnosticMessages.Add([string]$Object) }
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Security;
public static class MicroHackAzSecureParameterContract {
    public static bool IsNativeSecureString(Hashtable parameters, string name) {
        return parameters[name] is SecureString;
    }
}
'@
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Throws([scriptblock]$Operation, [string]$Expected) {
    $threw = $false
    try { & $Operation | Out-Null }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Expected) { throw "Unexpected failure: $($_.Exception.Message)" }
    }
    Assert-True $threw "Expected rejection: $Expected"
}

$sub = '11111111-1111-1111-1111-111111111111'
$user = '22222222-2222-2222-2222-222222222222'
$user2 = '44444444-4444-4444-4444-444444444444'
$script:administrator = '33333333-3333-3333-3333-333333333333'
$script:userResolution = 'valid'
$script:contextSubscription = $sub
$script:groups = @{}
$script:resources = @{}
$script:subnets = @()
$script:deployments = @()
$script:imageReads = 0
$script:failDeployment = $false
$script:throwDeployment = $false
$script:failDiagnosticReads = $false
$script:diagnosticReads = 0
$script:lastBootstrap = ''
$script:skuReads = 0
$script:capacityStates = @('Creating','Active')
$script:sleeps = 0
$script:foreignSkuPage = $false
$script:providerState = 'NotRegistered'
$script:registrationPollsRemaining = 1
$script:registrationRequests = @()
$script:stallRegistration = $false
$script:denyRegistration = $false
$script:httpResponses = [Collections.Generic.List[Net.Http.HttpResponseMessage]]::new()
$otherId="/subscriptions/$sub/resourceGroups/unrelated/providers/Microsoft.Fabric/capacities/other-capacity"
$script:resources[$otherId]=[pscustomobject]@{
    ResourceId=$otherId;ResourceGroupName='unrelated';ResourceType='Microsoft.Fabric/capacities'
    Name='other-capacity';Tags=@{Owner='unrelated'}
}

# These are provider-boundary doubles. The real hooks and all their runtime
# settings, identity resolution, ownership, parameter building and polling run.
function Get-MhhStableHash {
    param([string[]]$Value, [int]$Length)
    ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes(($Value -join '|'))))).ToLowerInvariant().Substring(0, $Length)
}
function New-MhhStablePassword {
    param([string]$Purpose, [int]$Length, [switch]$AsSecureString)
    if ($AsSecureString) { return ConvertTo-SecureString 'Offline-Fixture-Only-1!' -AsPlainText -Force }
    return 'Offline-Fixture-Only-1!'
}
function Get-MhhLabUser {
    [CmdletBinding()]param([string]$UserId)
    if ($script:userResolution -eq 'missing') { return }
    if ($UserId -notin @($user, $user2)) { throw 'Unassigned participant lookup.' }
    [pscustomobject]@{
        Id = if ($script:userResolution -eq 'wrong-id') { $script:administrator } else { $UserId }
        UserPrincipalName = if ($script:userResolution -eq 'invalid-upn') { '' }
            elseif ($script:userResolution -eq 'duplicate' -or $UserId -eq $user) { 'participant-a@example.test' }
            else { 'participant-b@example.test' }
    }
}
function Get-AzContext {
    [CmdletBinding()]param()
    [pscustomobject]@{Subscription=@{Id=$script:contextSubscription}}
}
function Get-AzAccessToken {
    [CmdletBinding()]param($ResourceUrl)
    $claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (@{oid=$script:administrator} | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    @{Token=ConvertTo-SecureString "header.$claims.signature" -AsPlainText -Force}
}
function Get-AzResourceProvider {
    [CmdletBinding()]param($ProviderNamespace)
    if ($ProviderNamespace -eq 'Microsoft.Fabric' -and $script:providerState -eq 'Registering' -and -not $script:stallRegistration) {
        if ($script:registrationPollsRemaining -gt 0) { $script:registrationPollsRemaining-- }
        else { $script:providerState='Registered' }
    }
    [pscustomobject]@{
        RegistrationState=if($ProviderNamespace -eq 'Microsoft.Fabric'){$script:providerState}else{'Registered'}
        ResourceTypes=@([pscustomobject]@{ResourceTypeName='bastionHosts';Locations=@('Switzerland North','Sweden Central')})
    }
}
function Register-AzResourceProvider {
    [CmdletBinding()]param($ProviderNamespace)
    if ($script:denyRegistration) { throw 'Synthetic registration permission denial.' }
    $script:registrationRequests += $ProviderNamespace
    $script:providerState='Registering'
}
function Get-AzResourceGroup {
    [CmdletBinding()]param()
    @($script:groups.Values)
}
function New-AzResourceGroup {
    [CmdletBinding()]param($Name,$Location,$Tag)
    $script:groups[$Name]=[pscustomobject]@{ResourceGroupName=$Name;Location=$Location;Tags=$Tag}
}
function Set-AzResourceGroup {
    [CmdletBinding()]param($Name,$Tag)
    $script:groups[$Name].Tags=$Tag
}
function Get-AzResource {
    [CmdletBinding()]param($ResourceGroupName,$ResourceType)
    $values = if ($ResourceGroupName) { @($script:resources.Values | Where-Object ResourceGroupName -EQ $ResourceGroupName) } else { @($script:resources.Values) }
    if ($ResourceType) { return @($values | Where-Object ResourceType -EQ $ResourceType) }
    return $values
}
function Start-Sleep {
    param([int]$Seconds)
    $script:sleeps++
}
function Invoke-AzRestMethod {
    [CmdletBinding()]param($Method,$Path)
    if ($Path -match 'Microsoft.Fabric' -and $script:providerState -ne 'Registered') { throw 'Fabric metadata queried before provider registration completed.' }
    $body = if ($Path -match '/Microsoft.Fabric/skus\?') {
        $script:skuReads++
        if ($Path -match 'page=2') { '{"value":[{"name":"F16","locations":["Switzerland North","Sweden Central"]}]}' }
        else {
            $pageSub=if($script:foreignSkuPage){$user}else{$sub}
            @{value=@();nextLink="https://management.azure.com/subscriptions/$pageSub/providers/Microsoft.Fabric/skus?api-version=2023-11-01&page=2"} | ConvertTo-Json
        }
    } elseif ($Path -match '/versions\?') {
        $script:imageReads++
        '[{"name":"20348.100.1"},{"name":"20348.100.2"}]'
    } elseif ($Path -match '/subnets/') {
        $id = $Path.Split('?')[0]
        if ($id -notin $script:subnets) { throw 'Subnet was not created by the shared hook.' }
        @{id=$id} | ConvertTo-Json
    } elseif ($Path -match '/Microsoft.Fabric/capacities/') {
        $state=$script:capacityStates[0]
        if($script:capacityStates.Count -gt 1){$script:capacityStates=@($script:capacityStates | Select-Object -Skip 1)}
        @{sku=@{name='F16'};properties=@{provisioningState='Succeeded';state=$state}} | ConvertTo-Json -Depth 4
    } elseif ($Path -match '/disks/') {
        $disk = $script:resources[$Path.Split('?')[0]]
        @{managedBy=$disk.ManagedBy} | ConvertTo-Json
    } else { throw "Unexpected offline ARM path: $Path" }
    $message=[Net.Http.HttpResponseMessage]::new()
    $script:httpResponses.Add($message)
    [pscustomobject]@{StatusCode=200;Content=$body;Headers=$message.Headers}
}
function Update-AzTag {
    [CmdletBinding()]param($ResourceId,$Operation,$Tag)
    $script:resources[$ResourceId].Tags=$Tag
}
function New-AzResourceGroupDeployment {
    [CmdletBinding()]param($Name,$ResourceGroupName,$TemplateFile,$TemplateParameterObject,$Mode)
    if ($TemplateParameterObject.ContainsKey('bootstrapConfigurationBase64')) {
        Assert-True ([MicroHackAzSecureParameterContract]::IsNativeSecureString($TemplateParameterObject, 'adminPassword')) 'Az converter receives a native CLR SecureString password, not a PSObject wrapper'
        Assert-True ([MicroHackAzSecureParameterContract]::IsNativeSecureString($TemplateParameterObject, 'bootstrapConfigurationBase64')) 'Az converter receives a native CLR SecureString bootstrap parameter'
        $script:lastBootstrap=[pscredential]::new('fixture', $TemplateParameterObject.bootstrapConfigurationBase64).GetNetworkCredential().Password
    }
    if ($script:throwDeployment) {
        throw [InvalidOperationException]::new("SyntheticDeploymentValidationFailure Offline-Fixture-Only-1! $($script:lastBootstrap)")
    }
    if ($script:failDeployment) { return [pscustomobject]@{ProvisioningState='Failed'} }
    $p=$TemplateParameterObject
    $script:deployments += @{name=$Name; parameters=$p}
    $prefix="/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers"
    if ($Name -eq 'apbi-shared') {
        Assert-True ($p.capacityAdministrators.Count -eq 3 -and $p.capacityAdministrators[0] -eq $script:administrator -and
            $p.capacityAdministrators[1] -eq 'participant-a@example.test' -and
            $p.capacityAdministrators[2] -eq 'participant-b@example.test') 'Deployment principal plus exactly this subscription roster administer the capacity in stable order'
        foreach ($kind in @(
            @{type='Microsoft.Fabric/capacities';name=$p.capacityName},
            @{type='Microsoft.Network/virtualNetworks';name="vnet-$($p.suffix)"}
        )) {
            $id="$prefix/$($kind.type)/$($kind.name)"
            $script:resources[$id]=[pscustomobject]@{ResourceId=$id;ResourceGroupName=$ResourceGroupName;ResourceType=$kind.type;Name=$kind.name;Tags=$p.tags}
        }
        $script:subnets=@($p.participantSubnets | ForEach-Object { "$prefix/Microsoft.Network/virtualNetworks/vnet-$($p.suffix)/subnets/$($_.name)" })
        Assert-True ($p.participantSubnets.prefix -contains '10.90.0.64/26' -and $p.participantSubnets.prefix -contains '10.90.0.128/26') 'Bastion range is reserved; participant subnets do not overlap'
    } else {
        Assert-True ($p.adminPassword -is [securestring]) 'VM password passed as SecureString'
        Assert-True ($p.image.version -eq '20348.100.2') 'Exact shared-resolved image passed to participant'
        Assert-True ($p.subnetId -in $script:subnets) 'Participant NIC uses a shared-provisioned subnet'
        $guest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:lastBootstrap)) | ConvertFrom-Json
        Assert-True ($guest.source.files.Count -eq 25 -and $guest.packagePolicy -eq 'latest-stable-at-provisioning' -and $guest.scripts.initializer) 'Complete frozen-setup guest payload built without event file'
        Assert-True ($script:lastBootstrap.Length -gt 7000) 'Managed Run Command supports the real payload instead of a command-line limit'
        $vmId="$prefix/Microsoft.Compute/virtualMachines/vm-$($p.suffix)"
        $script:resources[$vmId]=[pscustomobject]@{ResourceId=$vmId;ResourceGroupName=$ResourceGroupName;ResourceType='Microsoft.Compute/virtualMachines';Name="vm-$($p.suffix)";Tags=$p.tags}
        $diskId="$prefix/Microsoft.Compute/disks/os-$($p.suffix)"
        $script:resources[$diskId]=[pscustomobject]@{ResourceId=$diskId;ResourceGroupName=$ResourceGroupName;ResourceType='Microsoft.Compute/disks';Name="os-$($p.suffix)";Tags=@{};ManagedBy=$vmId}
    }
    [pscustomobject]@{ProvisioningState='Succeeded'}
}
function Get-AzResourceGroupDeployment {
    [CmdletBinding()]param($Name,$ResourceGroupName)
    $script:diagnosticReads++
    if ($script:failDiagnosticReads) { throw 'Synthetic diagnostic read denied.' }
    [pscustomobject]@{DeploymentName=$Name;ProvisioningState='Failed';CorrelationId='offline-correlation-id'}
}
function Get-AzResourceGroupDeploymentOperation {
    [CmdletBinding()]param($DeploymentName,$ResourceGroupName)
    $script:diagnosticReads++
    if ($script:failDiagnosticReads) { throw 'Synthetic operation read denied.' }
    [pscustomobject]@{
        OperationId='offline-operation-id'
        Properties=[pscustomobject]@{
            ProvisioningState='Failed';StatusCode='Conflict'
            TargetResource=[pscustomobject]@{Id="/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/fixture";ResourceType='Microsoft.Compute/virtualMachines'}
            StatusMessage=[pscustomobject]@{error=@{code='SyntheticVmQuotaError';message="Offline-Fixture-Only-1! $($script:lastBootstrap)"}}
            Request='NEVER-LOG-REQUEST'
            Response='NEVER-LOG-RESPONSE'
        }
    }
}

$previousConfig = [Environment]::GetEnvironmentVariable('MHH_EVENT_CONFIG')
try {
    [Environment]::SetEnvironmentVariable('MHH_EVENT_CONFIG', $null)
    $wrappedPassword=New-MhhStablePassword -Purpose 'fixture' -Length 24 -AsSecureString
    Assert-True ($wrappedPassword -is [securestring] -and
        -not [MicroHackAzSecureParameterContract]::IsNativeSecureString(@{value=$wrappedPassword}, 'value')) 'Fixture reproduces PowerShell -is masking the CLR SecureString wrapper'
    $wrappedPassword.Dispose()
    $defaults=Get-Content -LiteralPath "$lab\lab-defaults.json" -Raw | ConvertFrom-Json
    $sharedArgs=@{SubscriptionId=$sub;PreferredLocation=@('unsupportedregion',$defaults.preferredLocation);AllowedEntraUserIds=@($user2,$user)}
    $sharedOutput = @(. "$lab\shared-deploy-lab.ps1" @sharedArgs)
    Assert-True ($sharedOutput.Count -eq 2) 'Shared hook completes using exactly the supported platform contract'
    $priorFingerprint = Get-LabFingerprint @{
        settings = (Read-LabSettings); administrator = $script:administrator; users = @($user, $user2)
    }
    Assert-True ($script:deployments[0].parameters.tags.LabConfig -eq $priorFingerprint) 'Permission-only rollout retains the previous shared ownership fingerprint for in-place updates'
    Assert-True ($sharedOutput[0].HackboxCredential.note -match 'capacity administrator') 'Participant capacity credential describes the broader administrative permission'
    Assert-True ($script:skuReads -eq 2 -and $script:sleeps -eq 3) 'Registration, F16 metadata pagination and Active readiness waits are exercised'
    Assert-True (($script:registrationRequests -join ',') -eq 'Microsoft.Fabric' -and $script:providerState -eq 'Registered') 'Missing Fabric provider is registered once and awaited before metadata/deployment'
    Assert-True ($script:deployments[0].parameters.location -eq 'switzerlandnorth') 'Platform defaults actually deploy shared infrastructure in Switzerland North'
    Assert-True ($script:resources[$otherId].Tags.Owner -eq 'unrelated') 'Unrelated subscription capacities are neither blocked nor adopted'
    $firstImageReads=$script:imageReads
    [Environment]::SetEnvironmentVariable('MHH_EVENT_CONFIG', 'Z:\not-supplied-by-platform.json')
    $defaultRegionArgs=$sharedArgs.Clone()
    $defaultRegionArgs.PreferredLocation=@()
    $null = . "$lab\shared-deploy-lab.ps1" @defaultRegionArgs
    Assert-True ($script:imageReads -eq $firstImageReads -and $script:groups.Count -eq 1) 'Shared retry retains image, ownership and single scope'
    Assert-True ($script:registrationRequests.Count -eq 1) 'Registered providers are not registered again on retry'
    foreach ($identity in @($user,$user2)) {
        $rg=if($identity -eq $user){'rg-participant-a'}else{'rg-participant-b'}
        $script:groups[$rg]=[pscustomobject]@{ResourceGroupName=$rg;Location='unsupportedregion';Tags=@{Platform='keep'}}
        $argsForUser=@{DeploymentType='resourcegroup';SubscriptionId=$sub;ResourceGroupName=$rg;PreferredLocation=@();AllowedEntraUserIds=@($identity)}
        $output=@(. "$lab\deploy-lab.ps1" @argsForUser)
        Assert-True ($output.Count -eq 4) 'Participant credentials and private Bastion connection output returned after success'
        Assert-True ($script:groups[$rg].Tags.Platform -eq 'keep') 'Platform tags retained despite different RG metadata region'
        $before=$script:resources.Count
        $null=. "$lab\deploy-lab.ps1" @argsForUser
        Assert-True ($script:resources.Count -eq $before) 'Participant retry converges without duplicate resources'
    }
    Assert-True (@($script:resources.Values | Where-Object ResourceType -EQ 'Microsoft.Compute/virtualMachines').Count -eq 2) 'Two distinct participant VMs'
    $before=$script:deployments.Count
    $script:contextSubscription=$user
    Assert-Throws { . "$lab\shared-deploy-lab.ps1" @sharedArgs } 'context subscription mismatch'
    $script:contextSubscription=$sub
    $script:administrator=$user
    Assert-Throws { . "$lab\shared-deploy-lab.ps1" @sharedArgs } 'nonparticipant capacity administrator'
    $script:administrator='33333333-3333-3333-3333-333333333333'
    foreach ($mode in 'missing', 'wrong-id', 'invalid-upn', 'duplicate') {
        $script:userResolution = $mode
        Assert-Throws { . "$lab\shared-deploy-lab.ps1" @sharedArgs } 'participant.*capacity-administrator user identit'
    }
    $script:userResolution = 'valid'
    Assert-Throws { . "$lab\deploy-lab.ps1" -DeploymentType subscription -SubscriptionId $sub } 'Only the resourcegroup'
    Assert-Throws { . "$lab\deploy-lab.ps1" -DeploymentType resourcegroup -SubscriptionId $sub -AllowedEntraUserIds @($user,$user2) } 'Exactly one'
    Assert-True ($script:deployments.Count -eq $before) 'Invalid inputs cause no deployment'
    $override=Get-LabPlatformContext $sub @('swedencentral') @($user)
    Assert-True (($override.Regions -join ',') -eq 'swedencentral') 'An explicit platform region override remains authoritative'
    $script:providerState='Registering'
    $script:registrationPollsRemaining=0
    $null=Get-LabPlatformContext $sub @() @($user)
    Assert-True ($script:providerState -eq 'Registered' -and $script:registrationRequests.Count -eq 1) 'An already Registering Fabric provider is awaited without duplicate registration'
    $before=$script:deployments.Count
    $beforeSkus=$script:skuReads
    $script:providerState='NotRegistered'
    $script:stallRegistration=$true
    Assert-Throws { . "$lab\shared-deploy-lab.ps1" @sharedArgs } 'registration wait limit'
    Assert-True ($script:deployments.Count -eq $before -and $script:skuReads -eq $beforeSkus) 'Registration timeout prevents metadata requests and all deployments'
    $script:providerState='NotRegistered'
    $script:denyRegistration=$true
    Assert-Throws { . "$lab\deploy-lab.ps1" @argsForUser } 'Register Microsoft.Fabric failed'
    Assert-True ($script:deployments.Count -eq $before) 'Participant hook registration denial prevents deployment'
    $script:denyRegistration=$false
    $script:stallRegistration=$false
    $script:providerState='Registered'
    $script:foreignSkuPage=$true
    Assert-Throws { Get-LabRegionImage $sub @('swedencentral') (Read-LabSettings) } 'pagination changed subscription'
    $script:foreignSkuPage=$false
    $script:capacityStates=@('Paused')
    Assert-Throws { . "$lab\shared-deploy-lab.ps1" @sharedArgs } 'capacity is not active'
    $script:capacityStates=@('Active')
    $script:failDeployment=$true
    Assert-Throws { . "$lab\shared-deploy-lab.ps1" @sharedArgs } 'did not complete successfully'
    Assert-Throws { . "$lab\deploy-lab.ps1" @argsForUser } 'did not complete successfully'
    $script:failDeployment=$false
    $script:throwDeployment=$true
    $before=$script:diagnosticMessages.Count
    Assert-Throws { . "$lab\deploy-lab.ps1" @argsForUser } '^Participant ARM deployment failed\.'
    $logged=($script:diagnosticMessages | Select-Object -Skip $before) -join "`n"
    Assert-True ($script:diagnosticReads -eq 6 -and $logged -match 'offline-correlation-id' -and
        $logged -match 'SyntheticDeploymentValidationFailure' -and $logged -match 'SyntheticVmQuotaError') 'Thrown deployment errors collect real-hook exception, correlation and ARM operation diagnostics'
    Assert-True (-not $logged.Contains('Offline-Fixture-Only-1!') -and -not $logged.Contains($script:lastBootstrap) -and
        $logged -notmatch 'NEVER-LOG-REQUEST|NEVER-LOG-RESPONSE') 'Real-hook diagnostics never log VM password, bootstrap payload, operation request or response'
    $script:failDiagnosticReads=$true
    $before=$script:diagnosticMessages.Count
    Assert-Throws { . "$lab\deploy-lab.ps1" @argsForUser } '^Participant ARM deployment failed\.'
    $logged=($script:diagnosticMessages | Select-Object -Skip $before) -join "`n"
    Assert-True ($logged -match 'metadata unavailable' -and $logged -match 'operation inspection failed') 'Unavailable read-only diagnostics are explicit and preserve the original failure'
    Write-Output "PASS: $script:passed offline full-hook assertions. No cloud requests, installations or host changes."
} finally {
    foreach ($message in $script:httpResponses) { $message.Dispose() }
    [Environment]::SetEnvironmentVariable('MHH_EVENT_CONFIG', $previousConfig)
}
