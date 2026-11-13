@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The checker prints a human-readable table for operators and returns an object.
        'PSAvoidUsingWriteHost',
        # Internal helper functions in scripts, not exported cmdlets.
        'PSUseShouldProcessForStateChangingFunctions',
        # Tests deliberately shadow cmdlets with mocks.
        'PSAvoidOverwritingBuiltInCmdlets'
    )
}
