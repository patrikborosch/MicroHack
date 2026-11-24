param([Parameter(Mandatory)][string]$ConfigurationBase64, [string]$RunId = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-VerifiedAsset {
    param($Asset, [string]$Destination)
    $uri = [uri]$Asset.uri
    if ($uri.Scheme -ne 'https' -or $uri.Query -or $uri.UserInfo -or $uri.Fragment -or $Asset.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Invalid checksum-pinned public asset.'
    }
    if ($Asset.PSObject.Properties['cache']) {
        if ((Get-FileHash -LiteralPath $Asset.cache -Algorithm SHA256).Hash -ne $Asset.sha256) { throw 'Frozen asset cache checksum mismatch.' }
        Copy-Item -LiteralPath $Asset.cache -Destination $Destination -Force
        return
    }
    # Official release/Marketplace downloads redirect to their CDNs; bytes remain hash-pinned.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 300 -ErrorAction Stop | Out-Null
            break
        } catch {
            if ($attempt -eq 2) { throw 'Asset download failed after three bounded attempts.' }
            Start-Sleep -Seconds (2 * ($attempt + 1))
        }
    }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Asset.sha256) { throw 'Asset checksum mismatch.' }
}

function Expand-VerifiedZip {
    param([string]$Archive, [string]$Destination, [string[]]$AllowedRelativePaths = @())
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $total = 0L
        $seen = @{}
        if ($zip.Entries.Count -gt 30000) { throw 'Archive entry limit exceeded.' }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ($name -match '(^[\\]|:|(^|\\)\.\.?(\\|$))' -or
                $name -match '(?i)(^|\\)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\\|$)' -or
                $name.TrimEnd('\') -match '[. ](\\|$)' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe ZIP path or symbolic link.' }
            $key = $name.TrimEnd('\').ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw 'Duplicate archive entry.' }
            $seen[$key] = $true
            $total += $entry.Length
            if ($total -gt 3GB) { throw 'Archive expanded-size limit exceeded.' }
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $selected = $AllowedRelativePaths.Count -eq 0
            foreach ($allowed in $AllowedRelativePaths) {
                if ($name -eq $allowed -or $name.StartsWith($allowed.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $selected = $true }
            }
            if (-not $selected) { continue }
            if ($AllowedRelativePaths.Count -gt 0 -and $name -match '(?i)(^|\\)(coach|solutions?|walkthrough)(\\|$)') {
                throw 'Selected archive path contains coach content.'
            }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $target.StartsWith([IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escaped destination.' }
            if ($name.EndsWith('\')) { [IO.Directory]::CreateDirectory($target) | Out-Null }
            else {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
    } finally { $zip.Dispose() }
}

function Get-SafeSourcePath {
    param([string]$Root, [string]$Relative)
    if (-not $Relative -or $Relative -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$))' -or
        $Relative -match '(?i)(^|[\\/])(coach|solutions?|walkthrough)([\\/]|$)') { throw 'Unsafe student source path.' }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source path escaped archive root.' }
    if (-not (Test-Path -LiteralPath $full)) { throw 'Required student source missing from pinned archive.' }
    return $full
}

function Copy-StudentTree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw 'Required student source directory is missing.' }
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            $item.FullName -match '(?i)[\\/](coach|solutions?|walkthrough)([\\/]|$)') { throw 'Coach content or reparse point in student staging tree.' }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force |
        Copy-Item -Destination $Destination -Recurse -Force -ErrorAction Stop
}

function Assert-CsvManifest {
    param([string]$StudentRoot)
    $manifest = Get-Content -LiteralPath (Join-Path $StudentRoot 'datasets\manifest.json') -Raw | ConvertFrom-Json
    foreach ($scenario in 'banking', 'insurance') {
        $tables = $manifest.scenarios.$scenario.tables.PSObject.Properties
        if (@($tables).Count -lt 1) { throw 'Scenario manifest has no tables.' }
        foreach ($table in $tables) {
            $entry = $table.Value
            if ($entry.file.Replace('\', '/') -notlike "$scenario/*.csv") { throw 'Manifest references an unexpected scenario path.' }
            $path = Get-SafeSourcePath (Join-Path $StudentRoot 'datasets') $entry.file
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256 -or
                (Get-Item -LiteralPath $path).Length -ne $entry.bytes) { throw 'Staged CSV manifest checksum/size mismatch.' }
        }
    }
}

function Copy-LabStudentFiles {
    param($Source, [string]$StudentRoot)
    if ($Source.ref -notmatch '^[a-f0-9]{40}$') { throw 'Student source requires an immutable commit.' }
    foreach ($file in $Source.files) {
        $relative = $file.target.Replace('/', '\')
        $path = $file.path.Replace('/', '\')
        if ($relative -notmatch '^(datasets|briefs)\\' -or
            $path -notmatch '^(datasets|resources)\\' -or
            "$relative\$path" -match '(^|\\)\.\.?($|\\)|:|(?i)(^|\\)(coach|solutions?|walkthrough)(\\|$)') { throw 'Unsafe student target or source.' }
        $target = [IO.Path]::GetFullPath((Join-Path $StudentRoot $relative))
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        $segments = $file.path.Replace('\', '/') -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }
        $uri = "https://raw.githubusercontent.com/microsoft/MicroHack/$($Source.ref)/03-Azure/01-02%20Data/04-Agentic_PBIReport_Development/" + ($segments -join '/')
        Get-VerifiedAsset @{uri=$uri; sha256=$file.sha256} $target
    }
}

function Invoke-LabBootstrap {
    param([string]$EncodedConfiguration)
    $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedConfiguration)) | ConvertFrom-Json
    $root = 'C:\MicroHack'
    $marker = Join-Path $root 'bootstrap-complete.sha256'
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($EncodedConfiguration)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    if (Test-Path -LiteralPath $marker) {
        if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $fingerprint) { throw 'Bootstrap configuration changed; preserve participant work and rebuild an approved empty VM.' }
        Assert-CsvManifest (Join-Path $root 'student')
        $packages = Get-Content -LiteralPath "$root\host\packages\packages.lock.json" -Raw | ConvertFrom-Json
        foreach ($tool in $packages.tools) {
            if (-not (Test-Path -LiteralPath (Get-LabToolPath $tool))) { throw 'Completed bootstrap is missing a tool executable.' }
        }
        if (-not (Test-Path -LiteralPath "$root\tools\report\node_modules\.bin\powerbi-report-author.cmd")) { throw 'Completed bootstrap is missing report authoring.' }
        return
    }
    # A failed run owns only staging, never student work. A clean successful run is immutable.
    $staging = Join-Path $root 'staging'
    if (Test-Path -LiteralPath "$root\student") { throw 'Unmarked student tree exists; recover privately before bootstrap retry.' }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    . ([scriptblock]::Create($config.scripts.resolver))
    $packages = Resolve-LabPackages "$root\host\packages" $fingerprint
    $student = "$staging\student"
    Copy-LabStudentFiles $config.source $student
    Assert-CsvManifest $student
    @'
# Your Agentic Power BI exercise VM

Connect through Azure Bastion; this VM has no public IP. Run
`C:\MicroHack\initialize-user.ps1` after first login if setup did not run.
It prepares your own CLI skills and VS Code extensions. Sign in interactively,
open this student folder and verify the host and model with your coach.
Use `python datasets\generate-data.py --validate` before Challenge 1.
Business/design briefs are under `briefs`; the dictionary is under `datasets`.
The complete Fabric and Power BI skill bundles are frozen at provisioning.
Use the Start MicroHack shortcuts, which prepare your Windows profile offline.
Fabric Core MCP is configured in both hosts. Sign into GitHub/Copilot separately
from Fabric: use your assigned lab Entra identity for Fabric. Before Challenge 1,
discover the fabric-core tools and actually list workspaces through that server.
A configuration-complete message does not prove authentication or permissions.
CLI/REST tools complement MCP for authoring operations it does not support.
Do not update packages, extensions or plugins during this lab.
The frozen package/version record is C:\MicroHack\host\packages\packages.lock.json.

Follow the published lessons and the organizer's retention instructions.
Only the organizer removes shared resources after every participant is finished.
In addition to F16, shared Bastion, NAT and public IPs incur charges until removed;
deleting participant VMs or pausing F16 does not remove these shared resources.
'@ | Set-Content -LiteralPath "$student\README.md" -Encoding UTF8
    $skillsZip = "$staging\skills.zip"
    Get-VerifiedAsset $packages.skills $skillsZip
    Expand-VerifiedZip $skillsZip "$staging\skills"
    $skillRoot = Get-SafeSourcePath "$staging\skills" $packages.skills.root
    $snapshot = Join-Path $env:ProgramData "MicroHack\skills-for-fabric\$($packages.skills.commit)"
    $bundles = @(Initialize-LabFabricContent $skillRoot $student $snapshot $packages.skills.sha256)
    New-Item -ItemType Directory -Path "$root\host\extensions" -Force | Out-Null
    [IO.File]::WriteAllText("$root\initialize-user.ps1", $config.scripts.initializer, [Text.UTF8Encoding]::new($false))
    . "$root\initialize-user.ps1"
    Set-LabCoreMcp "$student\.vscode\mcp.json" 'servers'
    Set-LabEditorSettings "$student\.vscode\settings.json" -Project
    foreach ($extension in $packages.extensions) {
        Get-VerifiedAsset $extension "$root\host\extensions\$($extension.id).vsix"
    }
    New-Item -ItemType Directory -Path "$root\tools" -Force | Out-Null
    $pathEntries = @()
    foreach ($tool in $packages.tools) {
        $download = "$staging\$($tool.name).$($tool.format)"
        Get-VerifiedAsset $tool $download
        if ($tool.format -eq 'zip') {
            $destination = "$staging\tool-$($tool.name)"
            Expand-VerifiedZip $download $destination
            if (Test-Path -LiteralPath "$root\tools\$($tool.name)") { Remove-Item -LiteralPath "$root\tools\$($tool.name)" -Recurse -Force }
            Move-Item -LiteralPath $destination -Destination "$root\tools\$($tool.name)"
        } elseif ($tool.format -eq 'msi' -and $tool.name -eq 'azure-cli') {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$download`"", '/qn', '/norestart') -Wait -PassThru
            if ($process.ExitCode -notin 0, 3010) { throw 'Azure CLI MSI installation failed.' }
        } elseif ($tool.format -eq 'python' -and $tool.name -eq 'python') {
            $installer = "$staging\python.exe"
            Move-Item -LiteralPath $download -Destination $installer -Force
            $process = Start-Process -FilePath $installer -ArgumentList @('/quiet','InstallAllUsers=1','PrependPath=0','Include_test=0',"TargetDir=$root\tools\python") -Wait -PassThru
            if ($process.ExitCode -notin 0, 3010) { throw 'Python installation failed.' }
        } else { throw 'Unsupported tool package.' }
        $executable = Get-LabToolPath $tool
        $versionOutput = Invoke-LabProfileCommand $executable @('--version')
        if ($versionOutput -notmatch [regex]::Escape($tool.version)) {
            throw "Pinned tool failed its exact version check: $($tool.name)"
        }
        $pathEntries += Split-Path -Parent $executable
    }
    $reportRoot = "$root\tools\report"
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    $env:Path = ($pathEntries -join ';') + ';' + $env:Path
    $node = Get-LabToolPath ($packages.tools | Where-Object name -EQ 'node')
    $npm = Join-Path (Split-Path -Parent $node) 'npm.cmd'
    if (-not (Test-Path -LiteralPath "$reportRoot\package-lock.json")) {
        $package = @{
            name = 'microhack-agentic-pbi-runtime'; version = '1.0.0'; private = $true
            dependencies = @{ '@microsoft/powerbi-report-authoring-cli' = $packages.report.version }
        }
        [IO.File]::WriteAllText("$reportRoot\package.json", ($package | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $null = Invoke-LabProfileCommand $npm @('install', '--prefix', $reportRoot, '--package-lock-only',
            '--ignore-scripts', '--no-audit', '--no-fund', "--registry=$($packages.report.registry)")
    }
    Complete-LabReportIntegrity "$reportRoot\package-lock.json" $node
    Assert-LabReportLock "$reportRoot\package-lock.json" $packages.report.version $node
    $null = Invoke-LabProfileCommand $npm @('ci', '--prefix', $reportRoot,
        '--ignore-scripts', '--no-audit', '--no-fund', "--registry=$($packages.report.registry)")
    $null = Invoke-LabProfileCommand "$reportRoot\node_modules\.bin\powerbi-report-author.cmd" @('--version')
    $pathEntries += "$reportRoot\node_modules\.bin"
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $segments = @($pathEntries) + @($machinePath.Split(';') | Where-Object { $_ -and $_ -notlike "$root\tools\*" })
    [Environment]::SetEnvironmentVariable('Path', ($segments -join ';'), 'Machine')
    [Environment]::SetEnvironmentVariable('COPILOT_AUTO_UPDATE', 'false', 'Machine')
    $env:COPILOT_AUTO_UPDATE = 'false'
    $launcher = @'
param([ValidateSet('CLI','VSCode')][string]$HostMode = 'CLI')
$ErrorActionPreference = 'Stop'
& C:\MicroHack\initialize-user.ps1
Set-Location -LiteralPath C:\MicroHack\student
if ($HostMode -eq 'CLI') { & C:\MicroHack\tools\copilot\copilot.exe --no-auto-update }
else { & C:\MicroHack\tools\vscode\bin\code.cmd C:\MicroHack\student }
'@
    Set-Content -LiteralPath "$root\Start-MicroHack.ps1" -Value $launcher -Encoding UTF8
    $files = @(
        Get-ChildItem -LiteralPath $snapshot -Recurse -File -Force
        Get-Item -LiteralPath "$root\initialize-user.ps1", "$root\Start-MicroHack.ps1", "$root\host\packages\packages.lock.json", "$reportRoot\package-lock.json"
        Get-ChildItem -LiteralPath "$root\host\extensions" -File
        foreach ($tool in $packages.tools) { Get-Item -LiteralPath (Get-LabToolPath $tool) }
    ) | ForEach-Object { @{ path = $_.FullName; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }
    @{
        marketplace = $snapshot; bundles = $bundles; files = @($files)
        extensions = @($packages.extensions | ForEach-Object {
            @{ id = $_.id; version = $_.version; path = "$root\host\extensions\$($_.id).vsix" }
        })
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$root\host\host-manifest.json" -Encoding UTF8
    foreach ($path in @($snapshot, "$root\host", "$root\tools")) { Set-LabSharedContentAcl $path }
    foreach ($mode in 'CLI', 'VSCode') {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "Start MicroHack $mode.lnk"))
        $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $shortcut.Arguments = "-NoProfile -NoExit -ExecutionPolicy Bypass -File C:\MicroHack\Start-MicroHack.ps1 -HostMode $mode"
        $shortcut.WorkingDirectory = "$root\student"
        $shortcut.Save()
    }
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\MicroHackAgenticPBI' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\MicroHackAgenticPBI' -Name 'StubPath' `
        -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\MicroHack\initialize-user.ps1'
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\MicroHackAgenticPBI' -Name 'Version' -Value '3,0,0,0'
    Move-Item -LiteralPath $student -Destination "$root\student"
    Set-Content -LiteralPath $marker -Value $fingerprint -Encoding ASCII
    Remove-Item -LiteralPath $staging -Recurse -Force
}

function Initialize-LabFabricContent {
    param([string]$SourceRoot, [string]$StudentRoot, [string]$SnapshotRoot, [string]$ArchiveHash)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $catalog = Get-Content -LiteralPath "$SourceRoot\.github\plugin\marketplace.json" -Raw | ConvertFrom-Json
    $bundles = @()
    $selected = @()
    foreach ($name in 'fabric-skills', 'powerbi-authoring') {
        $entries = @($catalog.plugins | Where-Object name -EQ $name)
        if ($entries.Count -ne 1 -or $entries[0].source -ne "./plugins/$name") { throw "Unsupported upstream bundle layout: $name." }
        $entry = $entries[0]
        $entry.mcpServers = [pscustomobject]@{}
        $selected += $entry
        $bundles += @{ name = $name; version = $entry.version }
        $pluginRoot = "$SourceRoot\plugins\$name"
        foreach ($relative in '.github\plugin\plugin.json', '.claude-plugin\plugin.json') {
            $path = Join-Path $pluginRoot $relative
            $plugin = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($plugin.name -ne $name -or $plugin.version -ne $entry.version) { throw 'Upstream plugin manifest/catalog mismatch.' }
            $plugin.mcpServers = [pscustomobject]@{}
            [IO.File]::WriteAllText($path, ($plugin | ConvertTo-Json -Depth 20), $utf8)
        }
        [IO.File]::WriteAllText("$pluginRoot\.mcp.json", '{"mcpServers":{}}', $utf8)
    }
    $catalog.plugins = $selected
    foreach ($relative in '.github\plugin\marketplace.json', '.claude-plugin\marketplace.json') {
        [IO.File]::WriteAllText((Join-Path $SourceRoot $relative), ($catalog | ConvertTo-Json -Depth 20), $utf8)
    }
    [IO.File]::WriteAllText("$SourceRoot\.mcp.json", '{"mcpServers":{}}', $utf8)
    foreach ($name in 'spark-cli', 'semantic-model-authoring', 'powerbi-report-cli') {
        if (-not (Test-Path -LiteralPath "$SourceRoot\skills\$name\SKILL.md")) { throw "Required Fabric skill missing: $name." }
    }
    foreach ($folder in 'skills', 'common', 'agents') { Copy-StudentTree "$SourceRoot\$folder" "$StudentRoot\.github\$folder" }
    @'
# Frozen MicroHack environment

Use the installed Fabric skills and Fabric Core MCP from the beginning.
Before Challenge 1, authenticate fabric-core with the assigned lab Entra identity
and execute a read-only workspace-list call. GitHub/Copilot authentication and
Azure CLI authentication do not authenticate the MCP connection.
Use CLI/REST tools alongside MCP for unsupported authoring operations.
Create only Lakehouse, Notebook, SemanticModel and Report items in the assigned
workspace/capacity. Manual Fabric experimentation within that scope is allowed.
Do not check for or install newer tools, plugins, skills or extensions.
The VM's provisioning snapshot is fixed until destruction. Report missing or
changed components to the coach; do not overwrite student work or credentials.
'@ | Set-Content -LiteralPath "$StudentRoot\.github\copilot-instructions.md" -Encoding UTF8
    Set-Content -LiteralPath "$SourceRoot\.microhack-source.sha256" -Value $ArchiveHash -Encoding ASCII
    if (Test-Path -LiteralPath $SnapshotRoot) {
        if (-not (Test-Path -LiteralPath "$SnapshotRoot\.microhack-source.sha256") -or
            (Get-Content -LiteralPath "$SnapshotRoot\.microhack-source.sha256" -Raw).Trim() -ne $ArchiveHash) {
            throw 'Unowned or conflicting Fabric snapshot exists; it was not overwritten.'
        }
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $SnapshotRoot) -Force | Out-Null
        Move-Item -LiteralPath $SourceRoot -Destination $SnapshotRoot
    }
    return $bundles
}

function Set-LabSharedContentAcl {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(
        @('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute')
    )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($entry[0]), $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-LabToolPath {
    param($Tool)
    if ($Tool.format -eq 'zip') { return Join-Path "C:\MicroHack\tools\$($Tool.name)" $Tool.executable }
    return $Tool.executable
}

function Complete-LabReportIntegrity {
    param([string]$Path, [string]$NodeExecutable)
    $completeIntegrity = @'
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = process.argv[1];
async function run() {
    const lock = JSON.parse(fs.readFileSync(path, 'utf8'));
    if (!lock.packages || typeof lock.packages !== 'object' || Array.isArray(lock.packages)) {
        throw new Error('Report runtime lock has no package dictionary.');
    }
    let changed = false;
    for (const [name, pkg] of Object.entries(lock.packages)) {
        if (name === '') continue;
        if (!pkg || typeof pkg !== 'object' || typeof pkg.resolved !== 'string') {
            throw new Error(`Missing report dependency metadata: ${name}`);
        }
        let url = new URL(pkg.resolved);
        if (url.protocol !== 'https:' || url.username || url.password) {
            throw new Error(`Unsafe report dependency URL: ${name}`);
        }
        if (/^sha512-/.test(pkg.integrity)) continue;
        if (!/^sha1-[A-Za-z0-9+/]{27}=$/.test(pkg.integrity)) {
            throw new Error(`Unsupported report dependency checksum: ${name}`);
        }
        const signal = AbortSignal.timeout(120000);
        let response;
        for (let redirects = 0; redirects <= 5; redirects++) {
            response = await fetch(url, {redirect: 'manual', signal});
            if (![301, 302, 303, 307, 308].includes(response.status)) break;
            const location = response.headers.get('location');
            if (!location || redirects === 5) throw new Error(`Invalid report dependency redirect: ${name}`);
            url = new URL(location, url);
            if (url.protocol !== 'https:' || url.username || url.password) {
                throw new Error(`Unsafe report dependency redirect: ${name}`);
            }
            if (response.body) await response.body.cancel();
        }
        if (!response.ok || !response.body) throw new Error(`Report dependency download failed: ${name}`);
        const sha1 = crypto.createHash('sha1');
        const sha512 = crypto.createHash('sha512');
        for await (const chunk of response.body) {
            sha1.update(chunk);
            sha512.update(chunk);
        }
        if (`sha1-${sha1.digest('base64')}` !== pkg.integrity) {
            throw new Error(`Report dependency checksum mismatch: ${name}`);
        }
        pkg.microhackSourceIntegrity = pkg.integrity;
        pkg.integrity = `sha512-${sha512.digest('base64')}`;
        changed = true;
    }
    if (changed) {
        const temporary = `${path}.${crypto.randomUUID()}.tmp`;
        try {
            fs.writeFileSync(temporary, JSON.stringify(lock, null, 2) + '\n', {encoding: 'utf8', flag: 'wx'});
            fs.renameSync(temporary, path);
        } finally {
            if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
        }
    }
}
run().catch(error => { console.error(error.message); process.exitCode = 1; });
'@
    $null = Invoke-LabProfileCommand $NodeExecutable @('-e', $completeIntegrity, $Path)
}

function Assert-LabReportLock {
    param([string]$Path, [string]$ExpectedVersion, [string]$NodeExecutable)
    # npm's root package has an empty JSON key, which ConvertFrom-Json rejects in Windows PowerShell 5.1.
    $readEntries = @'
const fs = require('node:fs');
const lock = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
if (!lock.packages || typeof lock.packages !== 'object' || Array.isArray(lock.packages)) {
    throw new Error('Report runtime lock has no package dictionary.');
}
const entries = Object.entries(lock.packages).filter(([name]) => name !== '').map(([name, pkg]) => ({
    name,
    version: pkg.version ?? null,
    integrity: pkg.integrity ?? null,
    resolved: pkg.resolved ?? null
}));
process.stdout.write(JSON.stringify(entries));
'@
    $entries = Invoke-LabProfileCommand $NodeExecutable @('-e', $readEntries, $Path) | ConvertFrom-Json
    $entries = @($entries)
    $report = @($entries | Where-Object name -EQ 'node_modules/@microsoft/powerbi-report-authoring-cli')
    if ($report.Count -ne 1 -or $report[0].version -ne $ExpectedVersion) {
        throw 'Report runtime lock conflicts with the provisioning snapshot.'
    }
    foreach ($entry in $entries) {
        if ($entry.integrity -notmatch '^sha512-' -or $entry.resolved -notmatch '^https://') {
            throw 'Report runtime dependency lacks HTTPS/SHA512 integrity.'
        }
    }
}

# Dot-sourcing permits offline helper tests without modifying the host.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-LabBootstrap $ConfigurationBase64 }
    catch {
        [IO.Directory]::CreateDirectory('C:\MicroHack') | Out-Null
        [IO.File]::WriteAllText('C:\MicroHack\bootstrap-error.txt',
            [DateTimeOffset]::UtcNow.ToString('o') + "`r`n" + $_.Exception.Message +
            "`r`nErrorId: " + $_.FullyQualifiedErrorId + "`r`n" + $_.ScriptStackTrace)
        throw 'MicroHack bootstrap failed. Inspect C:\MicroHack\bootstrap-error.txt privately on the VM; no configuration body is emitted.'
    }
}
