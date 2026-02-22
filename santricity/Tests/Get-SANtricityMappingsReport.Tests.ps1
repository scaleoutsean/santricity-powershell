Describe 'santricity module basic' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '../santricity.psd1'
        Import-Module $modulePath -Force
    }

    It 'Connect-SANtricity returns summary object for valid args' {
        $res = Connect-SANtricity -BaseUrl 'https://example.com' -Username 'user' -Password 'pass' -VerifySsl:$true -SkipLogin
        $res.BaseUrls | Should -Contain 'https://example.com'
        $res.Validated | Should -BeFalse
        $res.StorageSystemId | Should -Be '1'
    }
}
