# specter-get-token.ps1
# Reads your stats.fm access token out of Specter's storage on a machine where
# Specter is ALREADY logged in, and copies it to the clipboard.
#
#   pwsh -File .\specter-get-token.ps1          # copy to clipboard, show masked
#   pwsh -File .\specter-get-token.ps1 -Show    # also print the full token
#
# Run as the same Windows user that is logged in to Specter.

[CmdletBinding()]
param([switch]$Show)

$ErrorActionPreference = 'Stop'
$prefix = 'Specter_VGhpcyBpcyB0aGUgcHJlZml4IGZv_'
$target = $prefix + 'authToken'

if (-not ('SpecterGet.Api' -as [type])) {
Add-Type -Namespace SpecterGet -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public struct CREDENTIAL {
  public uint Flags; public uint Type; public string TargetName; public string Comment;
  public long LastWritten; public uint CredentialBlobSize; public System.IntPtr CredentialBlob;
  public uint Persist; public uint AttributeCount; public System.IntPtr Attributes;
  public string TargetAlias; public string UserName;
}
[System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool CredReadW(string target, int type, int flags, out System.IntPtr cred);
[System.Runtime.InteropServices.DllImport("advapi32.dll")] public static extern void CredFree(System.IntPtr cred);
'@
}

$h = [System.IntPtr]::Zero
if (-not [SpecterGet.Api]::CredReadW($target, 1, 0, [ref]$h)) {
    $e = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($e -eq 1168) { throw "No credential '$target' found - is Specter logged in on THIS machine/user?" }
    throw "CredReadW failed (error $e)."
}
try {
    $c = [System.Runtime.InteropServices.Marshal]::PtrToStructure($h, [type][SpecterGet.Api+CREDENTIAL])
    $b = New-Object byte[] $c.CredentialBlobSize
    [System.Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $b, 0, $c.CredentialBlobSize)
} finally { [SpecterGet.Api]::CredFree($h) }

$token = [System.Text.Encoding]::UTF8.GetString($b).TrimEnd([char]0)
Set-Clipboard -Value $token

Write-Host "Token length : $($token.Length)"
Write-Host "Masked       : $($token.Substring(0,[Math]::Min(6,$token.Length)))...$($token.Substring([Math]::Max(0,$token.Length-4)))"
Write-Host "Copied to clipboard. On the VM run:  pwsh -File .\specter-link.ps1 -Token '<paste>'"
if ($Show) { Write-Host "`nFULL TOKEN:`n$token" }
