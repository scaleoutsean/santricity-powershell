function Read-SanmoxMultiSelection {
    [CmdletBinding()]
    param(
        [string]$Message,
        [Parameter(Mandatory=$true)]
        [array]$Choices,
        [array]$PreSelected = @()
    )

    $spectrePrompt = [Spectre.Console.MultiSelectionPrompt[string]]::new()
    $spectrePrompt = [Spectre.Console.MultiSelectionPromptExtensions]::AddChoices($spectrePrompt, [string[]]$Choices)
    
    if ($Message) { $spectrePrompt.Title = $Message }
    $spectrePrompt.PageSize = 10
    $spectrePrompt.WrapAround = $true
    $spectrePrompt.Required = $false
    $spectrePrompt.InstructionsText = "[$([Spectre.Console.Color]::Blue.ToMarkup())](Press [yellow]space[/] to toggle a choice and press [yellow]<enter>[/] to submit)[/]"

    # Pre-select matching choices
    foreach ($p in $PreSelected) {
        if ($Choices -contains $p) {
            [void][Spectre.Console.MultiSelectionPromptExtensions]::Select($spectrePrompt, [string]$p)
        }
    }

    return Invoke-SpectrePromptAsync -Prompt $spectrePrompt
}
