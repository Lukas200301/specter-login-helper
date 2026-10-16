# specter-link.ps1
# Logs Specter in without the phone app, by recreating the exact storage a real
# login produces: a Windows Credential Manager entry holding your stats.fm token,
# plus the "loggedIn" flag in shared_preferences.json.
#
# Run on the target machine/VM, as the Windows user that runs Specter, with
# Specter CLOSED. PowerShell 7 (pwsh) recommended.
#
#   pwsh -File .\specter-link.ps1 -Token "<YOUR_STATSFM_TOKEN>"
#   pwsh -File .\specter-link.ps1 -Revert
#
# Get <YOUR_STATSFM_TOKEN> from a logged-in machine with specter-get-token.ps1,
# or from https://stats.fm (F12 -> Network -> an api.stats.fm request ->
# Request Headers -> the 'authorization' value after "Bearer ").

[CmdletBinding()]
param(
    [string]$Token,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$prefix  = 'Specter_VGhpcyBpcyB0aGUgcHJlZml4IGZv_'
$target  = $prefix + 'authToken'
$appDir  = Join-Path $env:APPDATA 'stats.fm\Specter'
$prefsFile = Join-Path $appDir 'shared_preferences.json'

if (-not ('SpecterLink.Api' -as [type])) {
Add-Type -Namespace SpecterLink -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public struct CREDENTIAL {
  public uint Flags; public uint Type; public string TargetName; public string Comment;
  public long LastWritten; public uint CredentialBlobSize; public System.IntPtr CredentialBlob;
  public uint Persist; public uint AttributeCount; public System.IntPtr Attributes;
  public string TargetAlias; public string UserName;
}
[System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool CredWriteW(ref CREDENTIAL cred, uint flags);
[System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool CredDeleteW(string target, int type, int flags);
'@
}

function Set-Pref([string]$name, $value) {
    $data = @{}
    if (Test-Path $prefsFile) {
        try { (Get-Content -Raw $prefsFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $data[$_.Name] = $_.Value } } catch {}
    }
    $data[$name] = $value
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    $json = $data | ConvertTo-Json -Compress -Depth 10
    # Write UTF-8 WITHOUT BOM (Windows PowerShell 5.1's Set-Content adds a BOM that Flutter won't parse)
    [System.IO.File]::WriteAllText($prefsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

if ($Revert) {
    if ([SpecterLink.Api]::CredDeleteW($target, 1, 0)) { Write-Host "Deleted credential '$target'." }
    else { Write-Host "Credential '$target' not present." }
    Set-Pref 'flutter.loggedIn' $false
    Write-Host "Set flutter.loggedIn = false. Restart Specter."
    return
}

if ([string]::IsNullOrWhiteSpace($Token) -and $env:SPECTER_TOKEN) { $Token = $env:SPECTER_TOKEN }
if ([string]::IsNullOrWhiteSpace($Token)) { throw "Provide -Token '<your stats.fm access token>' (or set `$env:SPECTER_TOKEN)." }
$Token = $Token.Trim() -replace '^Bearer\s+',''

# Store the token as a GENERIC credential (NUL-terminated UTF-8, local-machine persist).
$bytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
$blob  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length + 1)
try {
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $blob, $bytes.Length)
    [System.Runtime.InteropServices.Marshal]::WriteByte($blob, $bytes.Length, 0)   # trailing NUL
    $cred = New-Object SpecterLink.Api+CREDENTIAL
    $cred.Type              = 1          # CRED_TYPE_GENERIC
    $cred.TargetName        = $target
    $cred.CredentialBlobSize = [uint32]($bytes.Length + 1)
    $cred.CredentialBlob    = $blob
    $cred.Persist           = 2          # CRED_PERSIST_LOCAL_MACHINE
    if (-not [SpecterLink.Api]::CredWriteW([ref]$cred, 0)) {
        throw "CredWriteW failed (error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
} finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($blob) }

Set-Pref 'flutter.loggedIn' $true

Write-Host "Wrote credential '$target' (token length $($Token.Length))."
Write-Host "Set flutter.loggedIn = true in $prefsFile"
Write-Host "Start Specter - it should open already logged in."
Write-Host "Undo:  pwsh -File .\specter-link.ps1 -Revert"
