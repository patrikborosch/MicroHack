param([string]$LabRoot = 'C:\MicroHack')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-LabUserJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($value -isnot [pscustomobject]) { throw "Expected a JSON object in $Path; existing configuration was not replaced." }
    return $value
}

function Write-LabUserJson {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 40
    if ((Test-Path -LiteralPath $Path) -and (Get-Content -LiteralPath $Path -Raw).Trim() -ceq $json.Trim()) { return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, "$Path.microhack-backup-$([guid]::NewGuid().ToString('N'))")
        }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Set-LabCoreMcp {
    param([string]$Path, [string]$Container)
    $document = Read-LabUserJson $Path
    if (-not $document.PSObject.Properties[$Container]) {
        $document | Add-Member -NotePropertyName $Container -NotePropertyValue ([pscustomobject]@{})
    }
    $servers = $document.$Container
    if ($servers -isnot [pscustomobject]) { throw "Invalid $Container in $Path." }
    $entry = $servers.PSObject.Properties['fabric-core']
    if ($entry) {
        if (-not $entry.Value.PSObject.Properties['type'] -or -not $entry.Value.PSObject.Properties['url'] -or
            $entry.Value.type -ne 'http' -or $entry.Value.url -ne 'https://api.fabric.microsoft.com/v1/mcp/core') {
            throw "Existing fabric-core entry conflicts with the lab in $Path; ask the coach to merge it."
        }
    } else {
        $server = [ordered]@{ type = 'http'; url = 'https://api.fabric.microsoft.com/v1/mcp/core' }
        if ($Container -eq 'mcpServers') { $server.tools = @('*') }
        $servers | Add-Member -NotePropertyName 'fabric-core' -NotePropertyValue ([pscustomobject]$server)
    }
    Write-LabUserJson $Path $document
}

function Set-LabEditorSettings {
    param([string]$Path, [switch]$Project)
    $settings = Read-LabUserJson $Path
    foreach ($pair in @{
        'extensions.autoUpdate' = $false
        'extensions.autoCheckUpdates' = $false
        'update.mode' = 'none'
    }.GetEnumerator()) {
        $settings | Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value -Force
    }
    if ($Project) { $settings | Add-Member -NotePropertyName 'chat.useAgentSkills' -NotePropertyValue $true -Force }
    Write-LabUserJson $Path $settings
}

function Invoke-LabProfileCommand {
    param([string]$Executable, [string[]]$Arguments)
    $null = Get-Command -Name $Executable -CommandType Application -ErrorAction Stop
    $preference = $ErrorActionPreference
    try {
        # Windows PowerShell otherwise terminates on benign native stderr before checking the exit code.
        $ErrorActionPreference = 'Continue'
        $output = & $Executable @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $preference }
    if ($null -eq $exitCode -or $exitCode -ne 0) { throw "Lab setup command failed: $([IO.Path]::GetFileName($Executable)) $($Arguments -join ' '). Inspect this command privately; setup was not marked complete." }
    return $output
}

function Invoke-LabUserInitialization {
    param([string]$Root, [string]$ProfileRoot, [string]$CodeUserRoot)
    $hostRoot = Join-Path $Root 'host'
    $manifestPath = Join-Path $hostRoot 'host-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        if (-not (Test-Path -LiteralPath $file.path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "Frozen lab content is missing or changed: $($file.path). Ask the coach to repair from this VM's snapshot; do not update."
        }
    }
    $target = Join-Path $ProfileRoot '.copilot'
    if ($env:COPILOT_HOME -and [IO.Path]::GetFullPath($env:COPILOT_HOME).TrimEnd('\') -ne [IO.Path]::GetFullPath($target)) {
        throw 'A custom COPILOT_HOME is set. Ask the coach to resolve it; the lab will not share or overwrite another profile.'
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    try {
        $setupLock = [IO.File]::Open((Join-Path $target 'microhack-setup.lock'), 'OpenOrCreate', 'Write', 'None')
    } catch [IO.IOException] {
        throw "Profile setup lock failed. Another profile initializer may be running; wait, then retry. If it persists, check profile storage/access. $($_.Exception.Message)"
    }
    $originalHome = $env:COPILOT_HOME
    $env:COPILOT_HOME = $target
    $env:COPILOT_AUTO_UPDATE = 'false'
    try {
        $settingsPath = Join-Path $target 'settings.json'
        $settings = Read-LabUserJson $settingsPath
        $settings | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $false -Force
        if (-not $settings.PSObject.Properties['extraKnownMarketplaces']) {
            $settings | Add-Member -NotePropertyName extraKnownMarketplaces -NotePropertyValue ([pscustomobject]@{})
        }
        $marketplaces = $settings.extraKnownMarketplaces
        $existing = $marketplaces.PSObject.Properties['fabric-collection']
        if ($existing) {
            $source = $existing.Value.PSObject.Properties['source']
            if (-not $source -or -not $source.Value.PSObject.Properties['source'] -or $source.Value.source -ne 'directory' -or
                -not $source.Value.PSObject.Properties['path'] -or $source.Value.path -ne $manifest.marketplace) {
                throw 'An existing fabric-collection marketplace points elsewhere; ask the coach to merge it. It was not overwritten.'
            }
            $existing.Value | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $false -Force
        }
        Write-LabUserJson $settingsPath $settings
        Set-LabCoreMcp (Join-Path $target 'mcp-config.json') 'mcpServers'
        Set-LabEditorSettings (Join-Path $CodeUserRoot 'settings.json')
        $copilot = Join-Path $Root 'tools\copilot\copilot.exe'
        $installed = Invoke-LabProfileCommand $copilot @('plugin', 'list', '--json') | ConvertFrom-Json
        $installed = @($installed)
        foreach ($bundle in $manifest.bundles) {
            foreach ($entry in @($installed | Where-Object name -EQ $bundle.name)) {
                if (-not $entry.PSObject.Properties['marketplace'] -or $entry.marketplace -ne 'fabric-collection' -or $entry.version -ne $bundle.version) {
                    throw "Existing plugin $($bundle.name) conflicts with the frozen lab bundle; ask the coach to merge it."
                }
            }
        }
        if (-not $existing) {
            $null = Invoke-LabProfileCommand $copilot @('plugin', 'marketplace', 'add', $manifest.marketplace)
            $settings = Read-LabUserJson $settingsPath
            $settings.extraKnownMarketplaces.'fabric-collection' | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $false -Force
            Write-LabUserJson $settingsPath $settings
        }
        foreach ($bundle in $manifest.bundles) {
            if (@($installed | Where-Object name -EQ $bundle.name).Count -eq 0) {
                $null = Invoke-LabProfileCommand $copilot @('plugin', 'install', "$($bundle.name)@fabric-collection")
            }
        }
        $installed = Invoke-LabProfileCommand $copilot @('plugin', 'list', '--json') | ConvertFrom-Json
        $installed = @($installed)
        foreach ($bundle in $manifest.bundles) {
            if (@($installed | Where-Object { $_.name -eq $bundle.name -and $_.version -eq $bundle.version -and $_.enabled }).Count -ne 1) {
                throw "Frozen plugin is missing or disabled: $($bundle.name)."
            }
        }
        $code = Join-Path $Root 'tools\vscode\bin\code.cmd'
        $extensions = Invoke-LabProfileCommand $code @('--list-extensions', '--show-versions')
        foreach ($extension in $manifest.extensions) {
            if ("$($extension.id)@$($extension.version)" -notin @($extensions -split '\r?\n')) {
                $null = Invoke-LabProfileCommand $code @('--install-extension', $extension.path, '--force', '--do-not-sync')
            }
        }
        $extensions = Invoke-LabProfileCommand $code @('--list-extensions', '--show-versions')
        foreach ($extension in $manifest.extensions) {
            if ("$($extension.id)@$($extension.version)" -notin @($extensions -split '\r?\n')) {
                throw "Frozen VS Code extension is missing: $($extension.id)."
            }
        }
        $status = [pscustomobject]@{
            snapshot = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
            configurationComplete = $true
            fabricAuthentication = 'NOT VERIFIED: sign in as the lab Entra identity and list workspaces through fabric-core.'
        }
        Write-LabUserJson (Join-Path $target 'microhack-configured.json') $status
        Write-Host 'Frozen lab configuration ready. GitHub sign-in and Fabric Core MCP sign-in/tool-call verification are separate, interactive steps.'
    } finally {
        $env:COPILOT_HOME = $originalHome
        $setupLock.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-LabUserInitialization $LabRoot $env:USERPROFILE (Join-Path $env:APPDATA 'Code\User')
}
