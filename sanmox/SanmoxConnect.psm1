function Connect-SanmoxEnvironment {
    [CmdletBinding()]
    param()

    Write-SpectreHost -Message "[cyan]Connecting to SANtricity Array...[/]"
    try {
        # Convert SecureString to plaintext for the module
        $plainPass = [System.Net.NetworkCredential]::new("", $Global:sanPass).Password
        
        $skipCert = if ($null -ne $Global:sanConfig.SkipCertificateCheck) { [bool]$Global:sanConfig.SkipCertificateCheck } else { $false }
        
        $sanParams = @{
            BaseUrl  = $Global:sanConfig.SanApiUri
            Username = $Global:sanConfig.SanUser
            Password = $plainPass
        }
        if ($skipCert) {
            $sanParams.Add('SkipCertificateCheck', $true)
        }
        $sanParams.Add('ValidateConnection', $true)
        
        $connResult = Connect-SANtricity @sanParams
        
        if ($null -ne $connResult.ValidationError) {
            throw $connResult.ValidationError
        } elseif ($connResult.Validated -ne $true) {
            throw "Login failed or connection could not be validated."
        }

        $Global:sanConnected = $true
        # Explicit string to prevent array/json deserialization issues
        $apiUriStr = $Global:sanConfig.SanApiUri.ToString().Replace('[', '[[').Replace(']', ']]')
        Write-SpectreHost -Message "[green]Successfully connected to SANtricity array at $apiUriStr[/]"
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to connect to SANtricity: $err[/]"
        $Global:sanConnected = $false
        Write-SpectreHost -Message "[yellow]Continuing in degraded mode (SANtricity offline)...[/]"
    }

    Write-SpectreHost -Message "[cyan]Connecting to Proxmox VE...[/]"
    try {
        $skipCert = if ($null -ne $Global:sanConfig.SkipCertificateCheck) { [bool]$Global:sanConfig.SkipCertificateCheck } else { $false }
        $pveUri = $Global:sanConfig.PveApiUri.TrimEnd('/')
        
        $pveUser = $Global:sanConfig.PveUser
        $pveSecret = if ($null -ne $Global:pvePass) { [System.Net.NetworkCredential]::new("", $Global:pvePass).Password } elseif ($Global:sanConfig.PveSecret) { $Global:sanConfig.PveSecret } else { "" }

        if ([string]::IsNullOrWhiteSpace($pveSecret)) {
            Write-SpectreHost -Message "[yellow]No PVE Secret found. Skipping PVE connection.[/]"
            $Global:pveConnected = $false
        } else {
            if ($pveUser -match '!') {
                # PVE API token header format: Authorization: PVEAPIToken=USER@REALM!TOKENID=UUID
                $Global:pveHeaders = @{
                    "Authorization" = "PVEAPIToken=$($pveUser)=$($pveSecret)"
                }
            } else {
                # PVE Username/Password Ticket Authentication
                $ticketParams = @{
                    Uri = "$pveUri/api2/json/access/ticket"
                    Method = "POST"
                    Body = @{ username = $pveUser; password = $pveSecret }
                }
                if ($skipCert) {
                    $ticketParams.Add('SkipCertificateCheck', $true)
                }
                $ticketResponse = Invoke-RestMethod @ticketParams
                $Global:PveTicketLast = $ticketResponse
                
                $Global:pveHeaders = @{
                    "CSRFPreventionToken" = $ticketResponse.data.CSRFPreventionToken
                    "Cookie" = "PVEAuthCookie=$($ticketResponse.data.ticket)"
                }
            }
            
            # Test connection
            $apiVersionParams = @{
                Uri = "$pveUri/api2/json/version"
                Method = "GET"
                Headers = $Global:pveHeaders
                SkipHeaderValidation = $true
            }
            if ($skipCert) {
                $apiVersionParams.Add('SkipCertificateCheck', $true)
            }
            $pveVersion = Invoke-RestMethod @apiVersionParams
            
            $Global:pveConnected = $true
            # Explicit string to prevent array/json deserialization issues
            $pveUriStr = $pveUri.ToString().Replace('[', '[[').Replace(']', ']]')
            Write-SpectreHost -Message "[green]Successfully connected to Proxmox VE at $pveUriStr (Version: $($pveVersion.data.version))[/]"
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to connect to Proxmox VE: $err[/]"
        $Global:pveConnected = $false
        Write-SpectreHost -Message "[yellow]Continuing in degraded mode (Proxmox VE offline)...[/]"
    }

    if (-not $Global:sanConnected -and -not $Global:pveConnected) {
        Write-SpectreHost -Message "[red]WARNING: Neither SANtricity nor Proxmox could be connected. Most operations will fail.[/]"
    }
}
