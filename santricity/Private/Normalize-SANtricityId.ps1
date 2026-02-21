
function Normalize-SANtricityId {
    <#
    .SYNOPSIS
    Normalize hex-like identifiers according to configured casing.

    .PARAMETER Id
    Identifier string to normalize.

    .DESCRIPTION
    Applies casing normalization (upper/lower) when configured; returns original string
    when `none` is selected.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')] 
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', '')]
    param([Parameter(Mandatory=$true)][string] $Id)
    
    # "Normalize" is not an approved verb, but this is an internal utility function.
    # We suppress the warning for this specific scope if PSSCriptAnalyzer is running, though
    # usually implicit for private functions if not exported.
    
    if (-not $Id) { return $Id }
    $cfg = $script:SANtricity_Config
    if (-not $cfg -or -not ($cfg.PSObject.Properties.Name -contains 'IdCase')) { return $Id }
    switch ($cfg.IdCase) {
        'upper' { return $Id.ToUpperInvariant() }
        'lower' { return $Id.ToLowerInvariant() }
        default { return $Id }
    }
}
