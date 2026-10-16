# specter-diagnose.ps1
# Read-only. Shows Specter's secure-storage folder, any existing *.secure files,
# and whether the AES-key credential exists. Run in PowerShell 7 (pwsh).

$ErrorActionPreference = 'Stop'
$prefix    = 'Specter_VGhpcyBpcyB0aGUgcHJlZml4IGZv_'
$appDir    = Join-Path $env:APPDATA 'stats.fm\Specter'
$credTarget = "key_$prefix"

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
$h = [System.IntPtr]::Zero
$ok = [SpecterDiag.Api]::CredReadW($credTarget, 1, 0, [ref]$h)
Write-Host "`nAES-key credential '$credTarget' present : $ok"
if ($ok) { [SpecterDiag.Api]::CredFree($h) }
else     { Write-Host "  (Specter hasn't created it yet - specter-link.ps1 will create it.)" }
Write-Host "`nDone. Paste this output back."
