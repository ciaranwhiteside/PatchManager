@{
    # PatchManager PSScriptAnalyzer settings.
    # Severity gate in CI: errors fail the build; warnings are reported.
    ExcludeRules = @(
        # Write-Host is intentional: PatchManager is an operator-facing console
        # script with colour-coded output, not a pipeline component.
        'PSAvoidUsingWriteHost'
        # ShouldProcess is superseded by the script's own -DryRun switch, which
        # covers every provider consistently.
        'PSUseShouldProcessForStateChangingFunctions'
        # WMI cmdlets are used deliberately for Win32_Battery on PS 5.1.
        'PSAvoidUsingWMICmdlet'
    )
}
