Describe 'Connect-SANtricity with TLS certificate bypass' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'santricity/santricity.psd1'
        Import-Module $modulePath -Force
    }

    It 'Connect-SANtricity stores VerifySsl config correctly' {
        $res = Connect-SANtricity -BaseUrl 'https://example.com' -Username 'admin' -Password 'password' -VerifySsl:$false -StorageSystemId '1'
        $res.VerifySsl | Should -BeFalse
        $res.StorageSystemId | Should -Be '1'
    }

    It 'Connect-SANtricity with VerifySsl true' {
        $res = Connect-SANtricity -BaseUrl 'https://example.com' -Username 'admin' -Password 'password' -VerifySsl:$true -StorageSystemId '1'
        $res.VerifySsl | Should -BeTrue
    }

    It 'Explicit StorageSystemId skips discovery' {
        $res = Connect-SANtricity -BaseUrl 'https://example.com' -Username 'admin' -Password 'password' -VerifySsl:$false -StorageSystemId 'explicit-id-123'
        $res.StorageSystemId | Should -Be 'explicit-id-123'
        $res.StorageSystemIdExplicit | Should -BeTrue
    }

    # This test requires an actual HTTPS endpoint with self-signed cert
    # Skipped in CI unless SANTRICITY_TEST_BASEURL is set
    It 'Can make HTTPS request with self-signed cert when VerifySsl is false' -Skip:(-not $env:SANTRICITY_TEST_BASEURL) {
        $baseUrl = $env:SANTRICITY_TEST_BASEURL
        $username = if ($env:SANTRICITY_TEST_USERNAME) { $env:SANTRICITY_TEST_USERNAME } else { 'admin' }
        $password = if ($env:SANTRICITY_TEST_PASSWORD) { $env:SANTRICITY_TEST_PASSWORD } else { 'admin' }
        
        # This should NOT throw SSL errors
        { 
            Connect-SANtricity -BaseUrl $baseUrl -Username $username -Password $password -VerifySsl:$false -StorageSystemId '1' -Verbose
        } | Should -Not -Throw
    }

    It 'HTTPS request with self-signed cert SHOULD fail when VerifySsl is true' -Skip:(-not $env:SANTRICITY_TEST_BASEURL) {
        $baseUrl = $env:SANTRICITY_TEST_BASEURL
        $username = if ($env:SANTRICITY_TEST_USERNAME) { $env:SANTRICITY_TEST_USERNAME } else { 'admin' }
        $password = if ($env:SANTRICITY_TEST_PASSWORD) { $env:SANTRICITY_TEST_PASSWORD } else { 'admin' }
        
        # This SHOULD throw SSL errors
        { 
            Connect-SANtricity -BaseUrl $baseUrl -Username $username -Password $password -VerifySsl:$true -StorageSystemId '1'
            # Try to make a request - this is where SSL validation happens
            Invoke-SANtricityRequest -Method GET -Path '/volumes' -UseSystemScope:$true
        } | Should -Throw
    }
}
