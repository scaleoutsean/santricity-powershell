
function Get-SANtricityTrustedCertificateInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw "Trusted certificate file not found: $fullPath"
    }

    $rawBytes = [System.IO.File]::ReadAllBytes($fullPath)
    $textSample = [System.Text.Encoding]::ASCII.GetString($rawBytes)
    $certs = [List[X509Certificate2]]::new()

    if ($textSample -match '-----BEGIN CERTIFICATE-----') {
        $pattern = '(?s)-----BEGIN CERTIFICATE-----\s*(?<body>.*?)\s*-----END CERTIFICATE-----'
        $foundMatches = [regex]::Matches($textSample, $pattern)
        foreach ($match in $foundMatches) {
            $body = $match.Groups['body'].Value -replace '\s+', ''
            if ([string]::IsNullOrWhiteSpace($body)) { continue }
            try {
                $certBytes = [Convert]::FromBase64String($body)
                $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
                $certs.Add($x509)
            } catch {
                Write-Warning "Failed to parse certificate block: $_"
            }
        }
    } else {
        $certs.Add([X509Certificate2]::new($rawBytes))
    }

    if ($certs.Count -eq 0) {
        throw "No certificates were found in $fullPath"
    }

    $leafThumbprints = [List[string]]::new()
    $rootThumbprints = [List[string]]::new()
    $rootCerts = [List[X509Certificate2]]::new()
    $intermediates = [List[X509Certificate2]]::new()

    foreach ($cert in $certs) {
        $isCa = $false
        foreach ($ext in $cert.Extensions) {
            $basic = $ext -as [X509BasicConstraintsExtension]
            if ($basic -and $basic.CertificateAuthority) {
                $isCa = $true
                break
            }
        }

        if ($isCa) {
            $rootThumbprints.Add($cert.Thumbprint)
            if ($cert.Subject -eq $cert.Issuer) {
                $rootCerts.Add($cert)
            } else {
                $intermediates.Add($cert)
            }
        } else {
            $leafThumbprints.Add($cert.Thumbprint)
        }
    }

    return [pscustomobject]@{
        Path = $fullPath
        RootCertificates = $rootCerts.ToArray()
        IntermediateCertificates = $intermediates.ToArray()
        LeafThumbprints = $leafThumbprints.ToArray()
        RootThumbprints = $rootThumbprints.ToArray()
    }
}
