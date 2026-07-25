# Daily inactive-user scan (04:30 UTC, after the 03:00 directory snapshot).
#
# Flags enabled accounts with no successful sign-in for the configured number
# of days (falling back to the account creation date for never-signed-in users)
# and runs the "inactive" trigger actions on them. Skips members of the
# configured exclusion group. No-op unless inactive monitoring is enabled in
# the admin web app.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'InactivityScanner' -Script {
    Invoke-ARInactivityScan
}
