Santricity PowerShell helper
=================================

Minimal PowerShell 7 module providing lightweight helpers to call a SANtricity
REST API and produce a mappings report similar to the Python client (`santricity-client`).

It has been tested with PowerShell 7.5 and 7.6 (Preview 6).

Usage (PowerShell 7):

```powershell
Import-Module ./santricity/santricity.psd1 -Force
# Optional rich tables (git clone https://github.com/dfinke/PowerShellRich.git)
Import-Module ./PowerShellRich/PowerShellRich.psd1 -ErrorAction SilentlyContinue

# For testing/lab (skips certificate validation):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -VerifySsl:$false -Verbose

# For production with controller or CA pinning (legacy pipeline implied when using -TrustedCertificate):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -TrustedCertificate '/path/to/controller-or-ca-chain.pem' -Verbose

Get-SANtricityVolumes -Verbose
Get-SANtricityMappingsReport | Format-Table -AutoSize
```

> **TLS note:** provide `-TrustedCertificate /path/chain.pem` with either a controller certificate or a custom CA bundle to enable pinned TLS. The module automatically routes requests through the legacy HttpClient pipeline in that case, so you only need `-VerifySsl:$false` for quick lab testing.

You may create a transcript (if you need one) with `-Create Transcript -TranscriptPath ts.txt`.

Some cmdlets do not behave exactly the same as the SANtricity API - we tend to err on the safe side. For example, SANtricity and SMcli [delete member hosts](https://docs.netapp.com/us-en/e-series-cli/commands-a-z/delete-hostgroup.html#context) when a group is deleted. We aim to prevent such disorderly entity removal by returning an error, but the user can override such safeguards with `-Force`. See [CMDLETS](./CMDLETS.md) and online help for more.
