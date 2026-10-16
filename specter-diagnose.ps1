# specter-diagnose.ps1
# Read-only. Shows where/how Specter stores its login so you can see what's set.
# Run in PowerShell 7 (pwsh) or Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'
$prefix       = 'Specter_VGhpcyBpcyB0aGUgcHJlZml4IGZv_'
$appDir       = Join-Path $env:APPDATA 'stats.fm\Specter'
$tokenTarget  = "$prefix" + 'authToken'   # old format: token lives here directly
$aesTarget    = "key_$prefix"             # new format: AES key for *.secure files

Write-Host "App support folder : $appDir"
Write-Host "Folder exists      : $(Test-Path $appDir)"
if (Test-Path $appDir) {
    Write-Host "`nFiles in folder:"
    Get-ChildItem -Force $appDir | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "`n*.secure files (key = name with prefix stripped):"
    Get-ChildItem -Force $appDir -Filter '*.secure' | ForEach-Object {
        $k = $_.Name -replace [regex]::Escape($prefix),'' -replace '\.secure$',''
        Write-Host ("  {0}   ->  key = '{1}'  ({2} bytes)" -f $_.Name, $k, $_.Length)
    }
    $sp = Join-Path $appDir 'shared_preferences.json'
    if (Test-Path $sp) { Write-Host "`nshared_preferences.json:"; Get-Content $sp | Write-Host }
}

# Does the AES-key credential exist? (classic Windows Credential Manager)
if (-not ('SpecterDiag.Api' -as [type])) {
Add-Type -Namespace SpecterDiag -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool CredReadW(string target, int type, int flags, out System.IntPtr cred);
[System.Runtime.InteropServices.DllImport("advapi32.dll")] public static extern void CredFree(System.IntPtr cred);
'@
}
function Test-Cred([string]$target) {
    $h = [System.IntPtr]::Zero
    $ok = [SpecterDiag.Api]::CredReadW($target, 1, 0, [ref]$h)
    if ($ok) { [SpecterDiag.Api]::CredFree($h) }
    return $ok
}

$tokenOk = Test-Cred $tokenTarget
$aesOk   = Test-Cred $aesTarget

Write-Host "`n--- Credential Manager ---"
Write-Host "TOKEN credential '$tokenTarget'"
Write-Host "  present : $tokenOk   <- this is what logs you in (old storage format)"
Write-Host "AES-key credential '$aesTarget'"
Write-Host "  present : $aesOk   (only used by newer builds with *.secure files)"

$sp = Join-Path $appDir 'shared_preferences.json'
$loggedIn = (Test-Path $sp) -and ((Get-Content -Raw $sp) -match '"flutter\.loggedIn"\s*:\s*true')

Write-Host "`n--- Verdict ---"
if ($tokenOk -and $loggedIn) {
    Write-Host "Looks LOGGED IN: token credential present and flutter.loggedIn=true."
} elseif ($tokenOk -or $aesOk) {
    Write-Host "Token stored, but flutter.loggedIn is not true - run specter-link.ps1 (sets both)."
} else {
    Write-Host "No token stored yet - run specter-login.ps1 or specter-link.ps1 to sign in."
}
Write-Host "`nDone. Paste this output back."
