Set-StrictMode -Version Latest

function Get-LabReleaseMetadata {
    param([string]$Uri, [object]$Body = $null)
    $parameters = @{
        Uri = $Uri; TimeoutSec = 120; ErrorAction = 'Stop'
        Headers = @{ 'User-Agent' = 'MicroHack-Agentic-PBI' }
    }
    if ($null -ne $Body) {
        $parameters.Method = 'Post'
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 12 -Compress
        $parameters.Headers.Accept = 'application/json;api-version=7.2-preview.1'
    }
    Invoke-RestMethod @parameters
}

function Get-LabGitHubPackage {
    param([string]$Repository, [string]$Name, [string]$Pattern, [string]$Format, [string]$Executable)
    $release = Get-LabReleaseMetadata "https://api.github.com/repos/$Repository/releases/latest"
    if ($release.prerelease -or $release.draft) { throw "Non-stable release returned for $Name." }
    $version = [regex]::Match($release.tag_name, '\d+\.\d+\.\d+').Value
    $assets = @($release.assets | Where-Object name -Match $Pattern)
    if (-not $version -or $assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "Latest $Name release has no unique Windows x64 asset with a publisher SHA256."
    }
    @{
        name = $Name; version = $version; format = $Format; executable = $Executable
        uri = $assets[0].browser_download_url; sha256 = $assets[0].digest.Substring(7)
    }
}

function Get-LabLatestPackages {
    $tools = @(
        Get-LabGitHubPackage 'PowerShell/PowerShell' 'powershell' '^PowerShell-[\d.]+-win-x64\.zip$' 'zip' 'pwsh.exe'
        Get-LabGitHubPackage 'git-for-windows/git' 'git' '^MinGit-[\d.]+-64-bit\.zip$' 'zip' 'cmd\git.exe'
        Get-LabGitHubPackage 'github/copilot-cli' 'copilot' '^copilot-win32-x64\.zip$' 'zip' 'copilot.exe'
        Get-LabGitHubPackage 'Azure/azure-cli' 'azure-cli' '^azure-cli-[\d.]+-x64\.msi$' 'msi' 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    )
    $nodeIndex = Get-LabReleaseMetadata 'https://nodejs.org/dist/index.json'
    $nodes = @($nodeIndex |
        Where-Object { $_.version -match '^v\d+\.\d+\.\d+$' -and 'win-x64-zip' -in $_.files } |
        Sort-Object { [version]$_.version.Substring(1) } -Descending)
    if (-not $nodes.Count) { throw 'No stable Windows x64 Node release.' }
    $node = $nodes[0].version
    $checksums = Invoke-WebRequest "https://nodejs.org/dist/$node/SHASUMS256.txt" -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $nodeFile = "node-$node-win-x64.zip"
    $hash = [regex]::Match([string]$checksums.Content, "(?m)^([a-f0-9]{64})\s+$([regex]::Escape($nodeFile))\s*$").Groups[1].Value
    if (-not $hash) { throw 'Node publisher checksum missing.' }
    $tools += @{
        name = 'node'; version = $node.Substring(1); format = 'zip'; executable = "node-$node-win-x64\node.exe"
        uri = "https://nodejs.org/dist/$node/$nodeFile"; sha256 = $hash
    }
    $code = Get-LabReleaseMetadata 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
    $tools += @{
        name = 'vscode'; version = $code.productVersion; format = 'zip'; executable = 'bin\code.cmd'
        uri = $code.url; sha256 = $code.sha256hash
    }
    if ($code.productVersion -notmatch '^\d+\.\d+\.\d+$' -or $code.sha256hash -notmatch '^[a-f0-9]{64}$') {
        throw 'VS Code stable release metadata lacks an exact version/publisher checksum.'
    }
    $pythonPage = Invoke-WebRequest 'https://www.python.org/downloads/windows/' -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $pythonLinks = @([regex]::Matches([string]$pythonPage.Content,
        'https://www\.python\.org/ftp/python/(\d+\.\d+\.\d+)/python-\1-amd64\.exe') |
        Sort-Object { [version]$_.Groups[1].Value } -Descending)
    if (-not $pythonLinks.Count) { throw 'No stable Windows x64 Python installer.' }
    $tools += @{
        name = 'python'; version = $pythonLinks[0].Groups[1].Value; format = 'python'
        executable = 'C:\MicroHack\tools\python\python.exe'; uri = $pythonLinks[0].Value; sha256 = $null
    }
    $commit = Get-LabReleaseMetadata 'https://api.github.com/repos/microsoft/skills-for-fabric/commits/main'
    if ($commit.sha -notmatch '^[a-f0-9]{40}$') { throw 'Fabric source did not resolve to an immutable commit.' }
    $extensions = @()
    foreach ($id in 'GitHub.copilot', 'GitHub.copilot-chat') {
        $gallery = Get-LabReleaseMetadata 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' @{
            filters = @(@{ criteria = @(@{ filterType = 7; value = $id }) }); flags = 4275
        }
        $versions = @($gallery.results[0].extensions[0].versions | Where-Object {
            $platform = $_.PSObject.Properties['targetPlatform']
            $_.version -match '^\d+\.\d+\.\d+$' -and
            (-not $platform -or -not $platform.Value -or $platform.Value -in 'win32-x64', 'universal') -and
            @($_.properties | Where-Object { $_.key -eq 'Microsoft.VisualStudio.Code.PreRelease' -and $_.value -eq 'true' }).Count -eq 0
        } | Sort-Object { [version]$_.version } -Descending)
        if (-not $versions.Count) { throw "No stable VSIX for $id." }
        $files = @($versions[0].files | Where-Object assetType -EQ 'Microsoft.VisualStudio.Services.VSIXPackage')
        if ($files.Count -ne 1) { throw "No unique VSIX asset for $id." }
        $extensions += @{ id = $id; version = $versions[0].version; uri = $files[0].source; sha256 = $null }
    }
    $registry = 'https://ms-feed-25.pkgs.visualstudio.com/1es-public/_packaging/npm-public/npm/registry'
    $report = Get-LabReleaseMetadata "$registry/@microsoft/powerbi-report-authoring-cli"
    $reportVersion = $report.'dist-tags'.latest
    if ($reportVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Report CLI latest tag is not a stable version.' }
    @{
        tools = $tools
        skills = @{
            commit = $commit.sha; root = "skills-for-fabric-$($commit.sha)"
            uri = "https://codeload.github.com/microsoft/skills-for-fabric/zip/$($commit.sha)"; sha256 = $null
        }
        extensions = $extensions
        report = @{ version = $reportVersion; registry = $registry }
    }
}

function Save-LabPackageAsset {
    param($Asset, [string]$Destination)
    $uri = [uri]$Asset.uri
    if ($uri.Scheme -ne 'https' -or $uri.Query -or $uri.UserInfo -or $uri.Fragment -or
        ($uri.Host -notin 'github.com', 'nodejs.org', 'www.python.org', 'codeload.github.com',
            'vscode.download.prss.microsoft.com' -and $uri.Host -notlike '*.gallerycdn.vsassets.io')) {
        throw 'Resolved package is not on an approved public release host.'
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        $partial = "$Destination.partial"
        try {
            Invoke-WebRequest -Uri $uri -OutFile $partial -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 600 -ErrorAction Stop | Out-Null
            if ($Asset.sha256 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Asset.sha256) {
                throw 'Publisher checksum mismatch.'
            }
            Move-Item -LiteralPath $partial -Destination $Destination
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Asset.sha256 -and $Asset.sha256 -ne $actual) { throw 'Frozen package checksum mismatch.' }
    $Asset.sha256 = $actual
}

function Resolve-LabPackages {
    param([string]$PackageRoot, [string]$ConfigurationFingerprint)
    New-Item -ItemType Directory -Path $PackageRoot -Force | Out-Null
    $lockPath = Join-Path $PackageRoot 'packages.lock.json'
    if (Test-Path -LiteralPath $lockPath) {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        if ($lock.configuration -ne $ConfigurationFingerprint) { throw 'Frozen package configuration changed; rebuild the VM.' }
    } else {
        $lock = Get-LabLatestPackages
        $lock.configuration = $ConfigurationFingerprint
        $lock.resolvedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $lock.complete = $false
        Write-LabPackageLock $lockPath $lock
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    }
    $assets = @($lock.tools) + @($lock.extensions) + @($lock.skills)
    for ($index = 0; $index -lt $assets.Count; $index++) {
        $asset = $assets[$index]
        $cache = Join-Path $PackageRoot "asset-$index"
        Save-LabPackageAsset $asset $cache
        $asset | Add-Member -NotePropertyName cache -NotePropertyValue $cache -Force
        Write-LabPackageLock $lockPath $lock
    }
    $lock.complete = $true
    Write-LabPackageLock $lockPath $lock
    return $lock
}

function Write-LabPackageLock {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText("$Path.partial", ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace("$Path.partial", $Path, "$Path.previous") }
    else { [IO.File]::Move("$Path.partial", $Path) }
}
