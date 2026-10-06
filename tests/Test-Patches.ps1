Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../SandFlix.Patches.psm1') -Force
function Assert-Rejected { param([scriptblock]$Action) $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; if(-not $rejected){throw 'Unsafe input was accepted.'} }
$manifest = '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.nuvio.tv"><uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/><application android:name="com.nuvio.tv.NuvioApplication" android:label="Nuvio"><activity android:name="com.nuvio.tv.launcher.AppIconDefault" android:label="Nuvio"/><activity android:name="com.nuvio.tv.launcher.AppIconGold" android:label="Nuvio"/></application></manifest>'
[xml]$patched = Convert-SandFlixManifest $manifest
$ns='http://schemas.android.com/apk/res/android'
if($patched.manifest.application.GetAttribute('label',$ns) -ne 'SandFlix'){throw 'Branding failed'}
foreach($a in $patched.manifest.application.activity){if($a.GetAttribute('label',$ns) -ne 'SandFlix'){throw 'Alias branding failed'}}
Assert-Rejected { Convert-SandFlixManifest ($manifest.Replace('package="com.nuvio.tv"','package="different.app"')) }
Assert-Rejected { Convert-SandFlixManifest ($manifest.Replace('com.nuvio.tv.launcher.AppIcon','changed.Launcher')) }
$updater = '.field public final a:Lcom/nuvio/tv/data/remote/api/GitHubReleaseApi;' + "`n" + 'const-string v8, "Empty GitHub release response"' + "`n" + 'const-string v2, "NuvioMedia"' + "`n" + 'const-string v3, "NuvioTV"'
$patchedUpdater=Convert-SandFlixUpdateRepository $updater 'sandycoon/SandFlix'
if($patchedUpdater -notmatch '"sandycoon"' -or $patchedUpdater -notmatch '"SandFlix"'){throw 'Update redirect failed'}
Assert-Rejected { Convert-SandFlixUpdateRepository $updater 'NuvioMedia/NuvioTV' }
Assert-Rejected { Convert-SandFlixUpdateRepository ($updater + "`n" + 'const-string v9, "NuvioMedia"') 'sandycoon/SandFlix' }
Assert-Rejected { Convert-SandFlixUpdateRepository $updater 'bad/owner/repo' }
if((Get-SandFlixVersionCode 1062) -ne 1001062){throw 'Version mapping failed'}
if((Get-SandFlixVersionCode 1063) -le (Get-SandFlixVersionCode 1062)){throw 'Version codes must increase'}
Assert-Rejected { Get-SandFlixVersionCode 1000000 }
Write-Host 'All customization and update-routing contract checks passed.'
