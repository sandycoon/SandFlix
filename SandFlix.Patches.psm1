Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-SandFlixManifest {
    param([Parameter(Mandatory)][string]$Text)
    [xml]$xml = $Text
    $ns = 'http://schemas.android.com/apk/res/android'
    if ($xml.manifest.package -ne 'com.nuvio.tv') { throw 'Unexpected upstream package.' }
    $app = $xml.manifest.application
    if ($app.GetAttribute('name', $ns) -ne 'com.nuvio.tv.NuvioApplication') {
        throw 'Unexpected upstream application. Review this release before building.'
    }
    $app.SetAttribute('label', $ns, 'SandFlix') | Out-Null
    $launchers = @($app.activity | Where-Object {
        $_.GetAttribute('name', $ns) -like 'com.nuvio.tv.launcher.AppIcon*'
    })
    if ($launchers.Count -eq 0) { throw 'Launcher layout changed. Review required.' }
    foreach ($launcher in $launchers) { $launcher.SetAttribute('label', $ns, 'SandFlix') | Out-Null }
    $installerPermission = @($xml.manifest.'uses-permission' | Where-Object {
        $_.GetAttribute('name', $ns) -eq 'android.permission.REQUEST_INSTALL_PACKAGES'
    })
    if ($installerPermission.Count -ne 1) { throw 'Updater install permission changed. Review required.' }
    return $xml.OuterXml
}

function Convert-SandFlixUpdateRepository {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Repository)
    if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$') {
        throw 'Use a GitHub owner/repository name.'
    }
    if ($Repository -eq 'NuvioMedia/NuvioTV') { throw 'Custom builds must never use upstream update downloads.' }
    if ($Text -notmatch 'Lcom/nuvio/tv/data/remote/api/GitHubReleaseApi;' -or
        $Text -notmatch 'Empty GitHub release response') { throw 'Unexpected update repository implementation.' }
    $parts = $Repository.Split('/')
    foreach ($pair in @(@('NuvioMedia', $parts[0]), @('NuvioTV', $parts[1]))) {
        $pattern = '(const-string(?:/jumbo)?\s+[vp]\d+,\s+")' + [regex]::Escape($pair[0]) + '(")'
        if ([regex]::Matches($Text, $pattern).Count -ne 1) {
            throw "Update repository constant changed: $($pair[0]). Review required."
        }
        $replacement = $pair[1]
        $Text = [regex]::Replace($Text, $pattern, {
            param($match) $match.Groups[1].Value + $replacement + $match.Groups[2].Value
        })
    }
    return $Text
}

function Get-SandFlixVersionCode {
    param([Parameter(Mandatory)][long]$UpstreamCode)
    if ($UpstreamCode -lt 1 -or $UpstreamCode -ge 1000000) {
        throw 'Upstream version code outside the reviewed range.'
    }
    return (1000000 + $UpstreamCode)
}

Export-ModuleMember -Function Convert-SandFlixManifest, Convert-SandFlixUpdateRepository, Get-SandFlixVersionCode
