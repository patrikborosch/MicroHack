param([switch]$Live)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$lab = Join-Path (Split-Path -Parent $PSScriptRoot) 'labautomation'
. "$lab\bootstrap.ps1" -ConfigurationBase64 'e30='
. "$lab\initialize-user.ps1"
. "$lab\resolve-packages.ps1"
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Throws([scriptblock]$Operation, [string]$Expected) {
    $threw = $false
    try { & $Operation | Out-Null }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Expected) { throw }
    }
    Assert-True $threw $Expected
}
# Keep the test's extraction prefix short, like the real Windows PowerShell guest path.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('mhf' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch | Out-Null
$originalHome = $env:COPILOT_HOME
$originalCache = $env:COPILOT_CACHE_HOME
$originalUpdate = $env:COPILOT_AUTO_UPDATE
try {
    $nativeShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $warning = Invoke-LabProfileCommand $nativeShell @('-NoProfile','-Command',"[Console]::Error.WriteLine('synthetic benign warning'); exit 0")
    Assert-True ($warning -match 'synthetic benign warning') 'Successful native stderr is captured without a false deployment failure in Windows PowerShell'
    Assert-Throws { Invoke-LabProfileCommand $nativeShell @('-NoProfile','-Command','exit 7') } 'Lab setup command failed'
    if ($Live) {
        $latest = Get-LabLatestPackages
        Assert-True ($latest.tools.Count -eq 7) 'All seven tools resolve from current official metadata'
        Assert-True (@($latest.tools | Where-Object version -NotMatch '^\d+\.\d+\.\d+$').Count -eq 0) 'No prerelease tool versions selected'
        $archive = Join-Path $scratch 'fabric.zip'
        Save-LabPackageAsset $latest.skills $archive
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $longest = ($zip.Entries | ForEach-Object { $_.FullName.Length } | Measure-Object -Maximum).Maximum
            Assert-True (('C:\MicroHack\staging\skills\'.Length + $longest) -lt 260) 'Full Fabric archive fits the actual Windows PowerShell guest extraction path limit'
        } finally { $zip.Dispose() }
        Expand-VerifiedZip $archive "$scratch\source"
        $source = Join-Path "$scratch\source" $latest.skills.root
        $expectedSkills = @(Get-ChildItem "$source\skills" -Directory).Count
        $bundles = @(Initialize-LabFabricContent $source "$scratch\student" "$scratch\snapshot" $latest.skills.sha256)
        Assert-True (@(Get-ChildItem "$scratch\student\.github\skills" -Directory).Count -eq $expectedSkills) 'Complete upstream skill catalog staged for VS Code'
        Assert-True (Test-Path "$scratch\student\.github\common") 'Shared relative references preserved'
        foreach ($relative in '.github\plugin\marketplace.json', '.claude-plugin\marketplace.json') {
            $catalog = Get-Content -LiteralPath (Join-Path "$scratch\snapshot" $relative) -Raw | ConvertFrom-Json
            $bytes = [IO.File]::ReadAllBytes((Join-Path "$scratch\snapshot" $relative))
            Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Adapted catalogs are BOM-free JSON in Windows PowerShell as well as PowerShell 7'
            Assert-True ($catalog.plugins.Count -eq 2 -and
                @($catalog.plugins | Where-Object { @($_.mcpServers.PSObject.Properties).Count -ne 0 }).Count -eq 0) 'Every host catalog excludes auxiliary/unpinned MCP registrations'
        }
        $env:COPILOT_HOME = "$scratch\profile\.copilot"
        $env:COPILOT_CACHE_HOME = "$scratch\copilot-cache"
        $env:COPILOT_AUTO_UPDATE = 'false'
        $cli = (Get-Command copilot -CommandType Application).Source
        $null = Invoke-LabProfileCommand $cli @('plugin', 'marketplace', 'add', "$scratch\snapshot")
        foreach ($bundle in $bundles) {
            $null = Invoke-LabProfileCommand $cli @('plugin', 'install', "$($bundle.name)@fabric-collection")
        }
        $plugins = Invoke-LabProfileCommand $cli @('plugin', 'list', '--json') | ConvertFrom-Json
        $plugins = @($plugins)
        foreach ($bundle in $bundles) {
            Assert-True (@($plugins | Where-Object { $_.name -eq $bundle.name -and $_.version -eq $bundle.version -and $_.enabled }).Count -eq 1) "Real CLI discovers frozen $($bundle.name)"
        }
        $settings = Read-LabUserJson "$env:COPILOT_HOME\settings.json"
        Assert-True ($settings.extraKnownMarketplaces.'fabric-collection'.source.path -eq "$scratch\snapshot" -and
            $settings.extraKnownMarketplaces.'fabric-collection'.source.source -eq 'directory') 'Local marketplace source schema matches profile initializer'
        $discovered = Invoke-LabProfileCommand $cli @('skill', 'list', '--json')
        foreach ($name in 'spark-cli', 'semantic-model-authoring', 'powerbi-report-cli') {
            Assert-True ($discovered -match [regex]::Escape($name)) "Real CLI discovers $name instructions"
        }
        $servers = Invoke-LabProfileCommand $cli @('mcp', 'list', '--json')
        Assert-True ($servers -notmatch 'powerbi-modeling-mcp|fabric-sqlendpoint|fabriciq\.svc|npx') 'Actual CLI does not load auxiliary or floating npx MCP servers'
        Set-LabCoreMcp "$env:COPILOT_HOME\mcp-config.json" 'mcpServers'
        $npm = (Get-Command npm.cmd -CommandType Application).Source
        $runtime = "$scratch\report"
        New-Item -ItemType Directory -Path $runtime | Out-Null
        Write-LabUserJson "$runtime\package.json" @{
            name='microhack-runtime-smoke';version='1.0.0';private=$true
            dependencies=@{'@microsoft/powerbi-report-authoring-cli'=$latest.report.version}
        }
        Set-Content -LiteralPath "$scratch\empty.npmrc" -Value ''
        $npmOptions = @('--ignore-scripts','--no-audit','--no-fund',"--prefix=$runtime",
            "--registry=$($latest.report.registry)","--cache=$scratch\npm-cache","--userconfig=$scratch\empty.npmrc")
        $null = Invoke-LabProfileCommand $npm (@('install','--package-lock-only') + $npmOptions)
        $null = Invoke-LabProfileCommand $npm (@('ci') + $npmOptions)
        $runtimeVersion = Invoke-LabProfileCommand "$runtime\node_modules\.bin\powerbi-report-author.cmd" @('--version')
        Assert-True ($runtimeVersion -match [regex]::Escape($latest.report.version)) 'Latest frozen report runtime installs without lifecycle scripts and starts'
        Write-Host "PASS: $script:passed live public-feed/archive/isolated CLI assertions; no cloud operations or authentication."
        return
    }
    & {
        function Get-LabReleaseMetadata([string]$Uri, $Body) {
            if ($Uri -match '/repos/(.+)/releases/latest$') {
                $assetName = switch ($Matches[1]) {
                    'PowerShell/PowerShell' { 'PowerShell-9.0.0-win-x64.zip' }
                    'git-for-windows/git' { 'MinGit-9.0.0-64-bit.zip' }
                    'github/copilot-cli' { 'copilot-win32-x64.zip' }
                    'Azure/azure-cli' { 'azure-cli-9.0.0-x64.msi' }
                }
                return [pscustomobject]@{
                    tag_name='v9.0.0';prerelease=$false;draft=$false
                    assets=@([pscustomobject]@{name=$assetName;digest=('sha256:'+('a'*64));browser_download_url="https://github.com/releases/$assetName"})
                }
            }
            switch ($Uri) {
                'https://nodejs.org/dist/index.json' {
                    return @(
                        [pscustomobject]@{version='v99.0.0-alpha.1';files=@('win-x64-zip')}
                        [pscustomobject]@{version='v25.0.0';files=@('win-x64-zip')}
                        [pscustomobject]@{version='v26.0.0';files=@('linux-x64')}
                        [pscustomobject]@{version='v24.0.0';files=@('win-x64-zip')}
                    )
                }
                'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest' {
                    return [pscustomobject]@{productVersion='1.2.3';url='https://vscode.download.prss.microsoft.com/test.zip';sha256hash=('a'*64)}
                }
                'https://api.github.com/repos/microsoft/skills-for-fabric/commits/main' { return [pscustomobject]@{sha=('a'*40)} }
                'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' {
                    return [pscustomobject]@{results=@([pscustomobject]@{extensions=@([pscustomobject]@{versions=@(
                        [pscustomobject]@{version='9.0.0';targetPlatform='win32-x64';properties=@([pscustomobject]@{key='Microsoft.VisualStudio.Code.PreRelease';value='true'});files=@()}
                        [pscustomobject]@{version='8.0.0';targetPlatform='linux-x64';properties=@();files=@()}
                        [pscustomobject]@{version='1.5.0';properties=@();files=@([pscustomobject]@{assetType='Microsoft.VisualStudio.Services.VSIXPackage';source='https://github.gallerycdn.vsassets.io/test.vsix'})}
                    )})})}
                }
                'https://ms-feed-25.pkgs.visualstudio.com/1es-public/_packaging/npm-public/npm/registry/@microsoft/powerbi-report-authoring-cli' {
                    return [pscustomobject]@{'dist-tags'=[pscustomobject]@{latest='1.3.0';beta='9.0.0-beta.1'}}
                }
                default { throw "Unexpected metadata request: $Uri" }
            }
        }
        function Invoke-WebRequest([string]$Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction) {
            switch ($Uri) {
                'https://nodejs.org/dist/v25.0.0/SHASUMS256.txt' { return @{Content=(('a'*64)+'  node-v25.0.0-win-x64.zip')} }
                'https://www.python.org/downloads/windows/' {
                    return @{Content='https://www.python.org/ftp/python/3.14.10/python-3.14.10-amd64.exe https://www.python.org/ftp/python/3.15.2/python-3.15.2-amd64.exe https://www.python.org/ftp/python/3.99.0b1/python-3.99.0b1-amd64.exe'}
                }
                default { throw "Unexpected text request: $Uri" }
            }
        }
        $selected = Get-LabLatestPackages
        Assert-True (($selected.tools | Where-Object name -EQ 'node').version -eq '25.0.0') 'Node selection rejects prereleases and releases without Windows assets'
        Assert-True (($selected.tools | Where-Object name -EQ 'python').version -eq '3.15.2') 'Python selects newest stable installer, not first link or prerelease'
        Assert-True (@($selected.extensions | Where-Object version -NE '1.5.0').Count -eq 0) 'VSIX selection rejects prerelease and non-Windows platform versions'
        Assert-True ($selected.report.version -eq '1.3.0') 'Report CLI follows stable tag, not beta'
    }
    $script:resolutions = 0
    function Get-LabLatestPackages {
        $script:resolutions++
        @{
            tools = @(@{ name='fixture'; version='1.0.0'; uri='https://github.com/example/release'; sha256=$null })
            extensions = @()
            skills = @{ commit=('a'*40); uri='https://codeload.github.com/example/archive'; sha256=$null }
            report = @{version='1.0.0'}
        }
    }
    $realSave = ${function:Save-LabPackageAsset}
    function Save-LabPackageAsset($Asset, [string]$Destination) {
        if (-not (Test-Path -LiteralPath $Destination)) { [IO.File]::WriteAllText($Destination, 'fixed fixture bytes') }
        & $realSave $Asset $Destination
    }
    $frozen = Resolve-LabPackages "$scratch\packages" 'configuration-one'
    $again = Resolve-LabPackages "$scratch\packages" 'configuration-one'
    Assert-True ($script:resolutions -eq 1 -and $again.resolvedAtUtc -eq $frozen.resolvedAtUtc) 'Retries never resolve newer releases'
    Assert-True ($again.complete -and $again.tools[0].sha256 -match '^[a-f0-9]{64}$') 'Snapshot records hashes and completion'
    Assert-Throws { Resolve-LabPackages "$scratch\packages" 'configuration-two' } 'rebuild the VM'
    [IO.File]::WriteAllText("$scratch\packages\asset-0", 'changed bytes')
    Assert-Throws { Resolve-LabPackages "$scratch\packages" 'configuration-one' } 'checksum mismatch'
    Assert-Throws { & $realSave @{uri='https://unapproved.example/release';sha256=$null} "$scratch\untrusted" } 'approved public release'

    $mcp = "$scratch\merge\mcp-config.json"
    Write-LabUserJson $mcp ([pscustomobject]@{mcpServers=[pscustomobject]@{personal=[pscustomobject]@{url='https://example.test/mcp'}}})
    Set-LabCoreMcp $mcp 'mcpServers'
    $merged = Read-LabUserJson $mcp
    Assert-True ($merged.mcpServers.personal.url -eq 'https://example.test/mcp' -and
        $merged.mcpServers.'fabric-core'.url -eq 'https://api.fabric.microsoft.com/v1/mcp/core') 'Core MCP merge preserves unrelated servers'
    $hash = (Get-FileHash $mcp).Hash
    $backups = @(Get-ChildItem (Split-Path -Parent $mcp) -Filter '*.microhack-backup-*').Count
    Set-LabCoreMcp $mcp 'mcpServers'
    Assert-True ((Get-FileHash $mcp).Hash -eq $hash -and
        @(Get-ChildItem (Split-Path -Parent $mcp) -Filter '*.microhack-backup-*').Count -eq $backups) 'Repeated setup does not rewrite files or multiply backups'
    $merged.mcpServers.'fabric-core'.url = 'https://conflict.test/mcp'
    Write-LabUserJson $mcp $merged
    $hash = (Get-FileHash $mcp).Hash
    Assert-Throws { Set-LabCoreMcp $mcp 'mcpServers' } 'conflicts'
    Assert-True ((Get-FileHash $mcp).Hash -eq $hash) 'Conflicting server is not overwritten'

    $root = "$scratch\lab"
    $snapshot = "$scratch\snapshot"
    New-Item -ItemType Directory -Path "$root\host", $snapshot -Force | Out-Null
    $bundles = @(@{name='fabric-skills';version='1.2.3'}, @{name='powerbi-authoring';version='1.2.3'})
    $manifest = @{
        marketplace=$snapshot; bundles=$bundles; files=@()
        extensions=@(@{id='GitHub.copilot';version='1.2.3';path="$scratch\GitHub.copilot.vsix"})
    }
    Write-LabUserJson "$root\host\host-manifest.json" $manifest
    $script:profiles = @{}
    $script:failExtension = $false
    function Invoke-LabProfileCommand([string]$Executable, [string[]]$Arguments) {
        $profile = $env:COPILOT_HOME
        if (-not $script:profiles.ContainsKey($profile)) { $script:profiles[$profile] = @{plugins=@();extensions=@();installs=0} }
        $state = $script:profiles[$profile]
        switch ($Arguments -join ' ') {
            'plugin list --json' { return ConvertTo-Json -InputObject @($state.plugins) -Depth 10 }
            'plugin install fabric-skills@fabric-collection' {
                $state.plugins += @{name='fabric-skills';version='1.2.3';marketplace='fabric-collection';enabled=$true}
                $state.installs++; return ''
            }
            'plugin install powerbi-authoring@fabric-collection' {
                $state.plugins += @{name='powerbi-authoring';version='1.2.3';marketplace='fabric-collection';enabled=$true}
                $state.installs++; return ''
            }
            '--list-extensions --show-versions' { return $state.extensions -join "`n" }
            default {
                if ($Arguments[0] -eq '--install-extension') {
                    if ($script:failExtension) { throw 'Synthetic VSIX failure' }
                    $state.extensions += 'GitHub.copilot@1.2.3'
                    return ''
                }
                if (($Arguments[0..2] -join ' ') -eq 'plugin marketplace add' -and $Arguments[3] -eq $snapshot) {
                    $settings = Read-LabUserJson "$profile\settings.json"
                    $settings.extraKnownMarketplaces | Add-Member -NotePropertyName 'fabric-collection' -NotePropertyValue (
                        [pscustomobject]@{source=[pscustomobject]@{source='directory';path=$snapshot};autoUpdate=$false})
                    Write-LabUserJson "$profile\settings.json" $settings
                    return ''
                }
                throw "Unexpected command: $($Arguments -join ' ')"
            }
        }
    }
    $env:COPILOT_HOME = $null
    New-Item -ItemType Directory -Path "$scratch\alice\.copilot\skills\personal" -Force | Out-Null
    Set-Content -LiteralPath "$scratch\alice\.copilot\skills\personal\SKILL.md" -Value 'Preserve personal skill'
    Set-Content -LiteralPath "$scratch\alice\.copilot\microhack-configured" -Value 'Old setup marker'
    Write-LabUserJson "$scratch\alice\.copilot\mcp-config.json" ([pscustomobject]@{mcpServers=[pscustomobject]@{personal=[pscustomobject]@{note='alice-only'}}})
    Invoke-LabUserInitialization $root "$scratch\alice" "$scratch\alice\Code\User"
    Invoke-LabUserInitialization $root "$scratch\alice" "$scratch\alice\Code\User"
    Assert-True ($script:profiles["$scratch\alice\.copilot"].installs -eq 2) 'Same Windows profile and different GitHub logins do not reinstall bundles'
    Assert-True ((Get-Content "$scratch\alice\.copilot\skills\personal\SKILL.md" -Raw).Trim() -eq 'Preserve personal skill') 'Existing personal skills and legacy marker do not block or get overwritten by frozen setup'
    $status = Read-LabUserJson "$scratch\alice\.copilot\microhack-configured.json"
    Assert-True ($status.configurationComplete -and $status.fabricAuthentication -like 'NOT VERIFIED*') 'Configuration readiness never claims successful Fabric authentication'
    $settings = Read-LabUserJson "$scratch\alice\Code\User\settings.json"
    Assert-True ($settings.'update.mode' -eq 'none' -and -not $settings.'extensions.autoUpdate' -and -not $settings.'extensions.autoCheckUpdates') 'VS Code updates disabled per Windows profile'
    Invoke-LabUserInitialization $root "$scratch\bob" "$scratch\bob\Code\User"
    $bob = Read-LabUserJson "$scratch\bob\.copilot\mcp-config.json"
    Assert-True (-not $bob.mcpServers.PSObject.Properties['personal'] -and
        $bob.mcpServers.'fabric-core'.url -eq 'https://api.fabric.microsoft.com/v1/mcp/core') 'Second Windows profile gets configuration, never another profile content/credentials'
    $script:failExtension = $true
    Assert-Throws { Invoke-LabUserInitialization $root "$scratch\retry" "$scratch\retry\Code\User" } 'Synthetic VSIX failure'
    Assert-True (-not (Test-Path "$scratch\retry\.copilot\microhack-configured.json")) 'Failed setup is not marked complete'
    $script:failExtension = $false
    Invoke-LabUserInitialization $root "$scratch\retry" "$scratch\retry\Code\User"
    Assert-True ($script:profiles["$scratch\retry\.copilot"].installs -eq 2) 'Interrupted setup repairs from the same local bundles without reinstalling completed plugins'
    $lockHandle = [IO.File]::Open("$scratch\alice\.copilot\microhack-setup.lock", 'Open', 'Write', 'None')
    try {
        Assert-Throws { Invoke-LabUserInitialization $root "$scratch\alice" "$scratch\alice\Code\User" } 'Another profile initializer'
    } finally { $lockHandle.Dispose() }
    $manifest.files = @(@{path="$scratch\missing-frozen-file";sha256=('a'*64)})
    Write-LabUserJson "$root\host\host-manifest.json" $manifest
    Assert-Throws { Invoke-LabUserInitialization $root "$scratch\alice" "$scratch\alice\Code\User" } 'Frozen lab content is missing or changed'
    Assert-True ($script:resolutions -eq 1 -and $env:COPILOT_AUTO_UPDATE -eq 'false') 'Profile setup never resolves latest or enables updates'
    Write-Host "PASS: $script:passed offline Fabric setup assertions. No cloud requests or host installations."
} finally {
    $env:COPILOT_HOME = $originalHome
    $env:COPILOT_CACHE_HOME = $originalCache
    $env:COPILOT_AUTO_UPDATE = $originalUpdate
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
