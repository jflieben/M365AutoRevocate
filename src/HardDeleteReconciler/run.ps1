# Watches the directory recycle bin for users pending permanent deletion (hard
# mode) and runs their revocation once they are gone (or one day before the
# automatic 30-day purge). In soft mode there is nothing to do.
#
# NB: delete timing lives in the BEHAVIOURAL config (config.json blob), not in
# app settings -- read it via Get-ARFeatureConfig.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'HardDeleteReconciler' -Script {
    $features = Get-ARFeatureConfig
    if ($features.mode -ne 'hard') {
        Write-Host "Delete timing is '$($features.mode)'; nothing for HardDeleteReconciler to do."
        return
    }
    Invoke-ARHardDeleteReconcile
}
