Santricity PowerShell helper
=================================

Minimal PowerShell 7 module providing lightweight helpers to call a SANtricity
REST API and produce a mappings report similar to the Python client.

Usage (PowerShell 7):

```powershell
Import-Module ./santricity.psm1
git clone https://github.com/dfinke/PowerShellRich
Import-Module PowerShellRich/PowerShellRich.psd1
Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -VerifySsl:$true
Get-SANtricityMappingsReport
```


