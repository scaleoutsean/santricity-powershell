Describe 'santricity module basic' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\santricity.psm1') -Force
    }

    It 'Connect-SANtricity returns true for valid args' {
        $res = Connect-SANtricity -BaseUrl 'https://example.com' -Username 'user' -Password 'pass' -VerifySsl:$true
        $res | Should -Be $true
    }
}
