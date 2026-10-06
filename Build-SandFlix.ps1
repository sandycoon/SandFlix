[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [Parameter(Mandatory)][string]$ReleaseRepository,
    [Parameter(Mandatory)][string]$KeystorePath,
    [string]$KeyAlias = 'sandflix-nuvio',
    [string]$ArtifactDirectory = (Join-Path $PSScriptRoot 'artifacts'),
    [string]$AndroidBuildTools,
    [string]$ApktoolPath,
    [string]$UpstreamApkPath,
    [switch]$UnsignedOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SandFlix.Patches.psm1') -Force

function Run-Native {
    param([string]$Tool, [string[]]$Arguments)
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Tool failed: $Tool (exit $LASTEXITCODE)" }
}
function Download-Verified {
    param([string]$Url, [string]$Path, [string]$Sha256)
    Invoke-WebRequest -Uri $Url -OutFile $Path -MaximumRedirection 10
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha256) {
        throw "Checksum mismatch for $([IO.Path]::GetFileName($Path))"
    }
}
function Read-ApkLibraries {
    param([string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $result = @{}
        foreach ($entry in $zip.Entries | Where-Object { $_.FullName -match '^lib/.+\.so$' }) {
            $stream = $entry.Open()
            $hash = [Security.Cryptography.SHA256]::Create()
            try { $result[$entry.FullName] = [Convert]::ToHexString($hash.ComputeHash($stream)) }
            finally { $stream.Dispose(); $hash.Dispose() }
        }
        if ($result.Count -eq 0) { throw 'No player native libraries found.' }
        return $result
    } finally { $zip.Dispose() }
}

if (-not $UnsignedOnly -and (-not $env:SANDFLIX_STORE_PASSWORD -or -not $env:SANDFLIX_KEY_PASSWORD)) {
    throw 'Set SANDFLIX_STORE_PASSWORD and SANDFLIX_KEY_PASSWORD in the environment. Never commit them.'
}
if (-not (Test-Path -LiteralPath $KeystorePath)) { throw 'Existing SandFlix signing key is required.' }
if (-not $AndroidBuildTools) {
    $AndroidBuildTools = Join-Path $env:LOCALAPPDATA 'Android/Sdk/build-tools/35.0.0'
}
foreach ($tool in 'aapt2.exe','zipalign.exe','apksigner.bat') {
    if (-not (Test-Path (Join-Path $AndroidBuildTools $tool))) { throw "Missing Android build tool: $tool" }
}
$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/java.exe' } else { 'java' }
Get-Command $java -ErrorAction Stop | Out-Null
$hasRipgrep = $null -ne (Get-Command rg -ErrorAction SilentlyContinue)
if ($ReleaseRepository -eq 'NuvioMedia/NuvioTV') { throw 'A custom release repository is required.' }

$headers = @{ 'User-Agent' = 'SandFlix-build'; 'Accept' = 'application/vnd.github+json' }
$endpoint = if ($Version -eq 'latest') { 'latest' } else { 'tags/' + [Uri]::EscapeDataString($Version) }
$release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/NuvioMedia/NuvioTV/releases/$endpoint"
if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Only reviewed stable semantic-version releases are supported.'
}
$Version = $release.tag_name
$assets = @($release.assets | Where-Object { $_.name -eq 'app-full-armeabi-v7a-release.apk' })
if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:([a-f0-9]{64})$') {
    throw 'Expected 32-bit APK or published checksum missing. Review required.'
}
$expectedUpstreamHash = $Matches[1]
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('sandflix-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
# Keep failed build folders for diagnosis; do not delete any user workspace.
Write-Host "Building SandFlix $Version; scratch folder: $scratch"
$upstream = Join-Path $scratch 'upstream.apk'
if ($UpstreamApkPath) {
    Copy-Item -LiteralPath $UpstreamApkPath -Destination $upstream
    if ((Get-FileHash $upstream -Algorithm SHA256).Hash -ne $expectedUpstreamHash) { throw 'Local upstream APK checksum mismatch.' }
} else {
    Download-Verified $assets[0].browser_download_url $upstream $expectedUpstreamHash
}
if (-not $ApktoolPath) {
    $ApktoolPath = Join-Path $scratch 'apktool.jar'
    $pin = Get-Content (Join-Path $PSScriptRoot 'apktool.sha256') -Raw
    Download-Verified 'https://github.com/iBotPeaches/Apktool/releases/download/v3.0.2/apktool_3.0.2.jar' $ApktoolPath $pin.Trim()
}
$decoded = Join-Path $scratch 'decoded'
Run-Native $java @('-jar', $ApktoolPath, 'd', '-o', $decoded, $upstream)
$manifestPath = Join-Path $decoded 'AndroidManifest.xml'
[IO.File]::WriteAllText($manifestPath, (Convert-SandFlixManifest ([IO.File]::ReadAllText($manifestPath))), [Text.UTF8Encoding]::new($false))
if ($hasRipgrep) {
    $updaterPaths = @(& rg -l --fixed-strings 'Empty GitHub release response' $decoded -g '*.smali')
} else {
    $smaliFiles = @(Get-ChildItem $decoded -Recurse -File -Filter '*.smali')
    $updaterPaths = @(Select-String -Path $smaliFiles.FullName -SimpleMatch -Pattern 'Empty GitHub release response' -List | ForEach-Object { $_.Path })
}
if ($updaterPaths.Count -ne 1) { throw 'Update repository could not be identified uniquely. Review required.' }
$updaterText = Convert-SandFlixUpdateRepository ([IO.File]::ReadAllText($updaterPaths[0])) $ReleaseRepository
[IO.File]::WriteAllText($updaterPaths[0], $updaterText, [Text.UTF8Encoding]::new($false))
# Official updater stays enabled; only its release repository is redirected.
if ($hasRipgrep) {
    $updaterViewModels = @(& rg -l --fixed-strings 'UpdateViewModel.kt' $decoded -g '*.smali')
} else {
    $updaterViewModels = @(Select-String -Path $smaliFiles.FullName -SimpleMatch -Pattern 'UpdateViewModel.kt' -List | ForEach-Object { $_.Path })
}
if ($updaterViewModels.Count -ne 1) { throw 'Updater structure changed. Review required.' }
if ([IO.File]::ReadAllText($updaterViewModels[0]) -notmatch 'launch\$default') { throw 'Updater unexpectedly disabled.' }

$brandingRoot = Join-Path $PSScriptRoot 'branding'
$brandingFiles = @(Get-ChildItem $brandingRoot -Recurse -File -Filter '*.png')
if ($brandingFiles.Count -ne 12) { throw 'Expected complete branding set missing.' }
foreach ($asset in $brandingFiles) {
    $relative = [IO.Path]::GetRelativePath($brandingRoot, $asset.FullName)
    $target = Join-Path (Join-Path $decoded 'res') $relative
    if (-not (Test-Path -LiteralPath $target)) { throw "Branding target changed: $relative" }
    Copy-Item -LiteralPath $asset.FullName -Destination $target -Force
}
# Reuse your red wordmark for all theme variants introduced in 1.0.0.
foreach ($asset in Get-ChildItem (Join-Path $decoded 'res/drawable') -Filter 'app_logo_wordmark_*.png') {
    Copy-Item (Join-Path $brandingRoot 'drawable/app_logo_wordmark.png') $asset.FullName -Force
}
foreach ($asset in Get-ChildItem (Join-Path $decoded 'res') -Recurse -File | Where-Object { $_.Name -match '^(banner|ic_launcher)_.+\.png$' }) {
    $base = if ($asset.Name -like 'banner_*') { 'banner.png' } else { 'ic_launcher.png' }
    $source = Join-Path $brandingRoot ($asset.Directory.Name + '/' + $base)
    if (-not (Test-Path -LiteralPath $source)) { throw "Unhandled launcher artwork: $($asset.FullName)" }
    Copy-Item -LiteralPath $source -Destination $asset.FullName -Force
}
$metadataPath = Join-Path $decoded 'apktool.yml'
$metadata = [IO.File]::ReadAllText($metadataPath)
$match = [regex]::Match($metadata, '(?m)^  versionCode: (\d+)\s*$')
if (-not $match.Success) { throw 'Missing upstream version code.' }
$upstreamCode = [long]$match.Groups[1].Value
$versionCode = Get-SandFlixVersionCode $upstreamCode
$metadata = [regex]::Replace($metadata, '(?m)^  versionCode: \d+\s*$', "  versionCode: $versionCode`n")
[IO.File]::WriteAllText($metadataPath, $metadata, [Text.UTF8Encoding]::new($false))
$unsigned = Join-Path $scratch 'unsigned.apk'
$aligned = Join-Path $scratch 'aligned.apk'
$output = Join-Path $ArtifactDirectory $(if ($UnsignedOnly) { 'sandflix-unsigned-validation.apk' } else { 'app-full-armeabi-v7a-release.apk' })
Run-Native $java @('-jar', $ApktoolPath, 'b', '--no-crunch', $decoded, '-o', $unsigned)
Run-Native (Join-Path $AndroidBuildTools 'zipalign.exe') @('-p','-f','4',$unsigned,$aligned)
if ($UnsignedOnly) {
    Copy-Item -LiteralPath $aligned -Destination $output -Force
} else {
    Run-Native (Join-Path $AndroidBuildTools 'apksigner.bat') @('sign','--ks',$KeystorePath,'--ks-key-alias',$KeyAlias,'--ks-pass','env:SANDFLIX_STORE_PASSWORD','--key-pass','env:SANDFLIX_KEY_PASSWORD','--v4-signing-enabled','false','--out',$output,$aligned)
    $verification = (& (Join-Path $AndroidBuildTools 'apksigner.bat') verify --verbose --print-certs $output) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $verification -notmatch 'Signer #1 certificate SHA-256 digest: e8ddfa16260fa5651b7b56b954c5eb7024f87ac9cf6368993600f433c12a3b79') {
        throw 'Signing verification failed or certificate differs from installed SandFlix.'
    }
}
Run-Native (Join-Path $AndroidBuildTools 'zipalign.exe') @('-c','4',$output)
$badging = (& (Join-Path $AndroidBuildTools 'aapt2.exe') dump badging $output) -join "`n"
if ($LASTEXITCODE -ne 0 -or $badging -notmatch "name='com.nuvio.tv' versionCode='$versionCode' versionName='$Version'" -or
    $badging -notmatch "application-label:'SandFlix'" -or $badging -notmatch "native-code: 'armeabi-v7a'") { throw 'APK metadata validation failed.' }
$originalLibraries = Read-ApkLibraries $upstream
$newLibraries = Read-ApkLibraries $output
if ($originalLibraries.Count -ne $newLibraries.Count) { throw 'Native player library set changed during customization.' }
foreach ($name in $originalLibraries.Keys) {
    if (-not $newLibraries.ContainsKey($name) -or $newLibraries[$name] -ne $originalLibraries[$name]) { throw "Native library changed: $name" }
}
$zip = [IO.Compression.ZipFile]::OpenRead($output)
try {
    foreach ($asset in $brandingFiles) {
        $name = 'res/' + [IO.Path]::GetRelativePath($brandingRoot, $asset.FullName).Replace('\','/')
        $entry = $zip.GetEntry($name)
        if (-not $entry) { throw "Branding missing from APK: $name" }
        $stream = $entry.Open(); $hash = [Security.Cryptography.SHA256]::Create()
        try { $actual = [Convert]::ToHexString($hash.ComputeHash($stream)) }
        finally { $stream.Dispose(); $hash.Dispose() }
        if ($actual -ne (Get-FileHash $asset.FullName -Algorithm SHA256).Hash) { throw "Branding changed: $name" }
    }
} finally { $zip.Dispose() }
$report = [ordered]@{
    upstreamTag = $Version; upstreamVersionCode = $upstreamCode; versionCode = $versionCode
    upstreamSha256 = $expectedUpstreamHash; apkSha256 = (Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant()
    updateRepository = $ReleaseRepository; signingCertificate = 'e8ddfa16260fa5651b7b56b954c5eb7024f87ac9cf6368993600f433c12a3b79'
    nativeLibrariesPreserved = $newLibraries.Count; brandingAssetsVerified = $brandingFiles.Count
    signatureVerified = (-not $UnsignedOnly); playbackTested = $false; builtAtUtc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $ArtifactDirectory 'build-report.json'), ($report | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Host "Verified SandFlix $Version build ready: $output"
