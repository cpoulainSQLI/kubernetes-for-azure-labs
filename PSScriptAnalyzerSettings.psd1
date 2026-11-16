# PSScriptAnalyzer settings for the course scripts.
# Run from the course root: Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # The scripts are interactive console tools that print coloured PASS, FAIL and WARN lines.
        'PSAvoidUsingWriteHost',
        # scripts/lib.ps1 defines variables for the scripts that dot-source it.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            # The scripts must run in Windows PowerShell 5.1, which ships with Windows.
            TargetVersions = @('5.1', '7.4')
        }
    }
}
