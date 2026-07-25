# Weekly version check (fires every 6h; only acts when the randomised
# nextCheckUtc has passed). Compares the deployed version against the public
# repo, surfaces an update in the admin console, and (unless disabled) emails
# the service desk once per new version. See VersionCheck.ps1.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'VersionChecker' -Script {
    Invoke-ARVersionCheck
}
