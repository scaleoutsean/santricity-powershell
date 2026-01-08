Santricity PowerShell helper
=================================

Minimal PowerShell 7 module providing lightweight helpers to call a SANtricity
REST API and produce a mappings report similar to the Python client.

Usage (PowerShell 7):

```powershell
Import-Module ./santricity/santricity.psd1 -Force
# Optional rich tables (bundled for convenience)
Import-Module ./PowerShellRich/PowerShellRich.psd1 -ErrorAction SilentlyContinue

# For testing/lab (skips certificate validation):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -VerifySsl:$false -Verbose

# For production with controller cert pinning:
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -UseLegacyHttpClient -TrustedCertificate '/path/to/controller-cert.pem' -Verbose

Get-SANtricityVolumes -Verbose
Get-SANtricityMappingsReport | Format-Table -AutoSize
```

> **TLS note:** the default pipeline (Invoke-RestMethod) only supports skipping validation via `-VerifySsl:$false`. Use `-UseLegacyHttpClient -TrustedCertificate /path/cert.pem` to pin a controller certificate via the HttpClient-based pipeline.

### Run tests inside Docker

If your host PowerShell setup is unreliable, you can run the test suite inside the
official .NET SDK 9.0 container:

```bash
docker compose run --rm powershell-tests
```

The first run installs PowerShell inside the container, then executes
`./scripts/run-tests.sh` against the workspace mounted at `/workspace`.


