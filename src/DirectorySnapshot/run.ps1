# Refreshes the cached directory snapshot (userId -> manager/profile/ownership)
# once a day. This cache is what lets the tool email the correct manager and list
# owned artifacts *after* a user is deleted, since Graph drops those
# relationships on deletion.
#
# The deploy script triggers the first run; after that it runs nightly.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'DirectorySnapshot' -Script {
    # Stay under the 30-minute host timeout with margin; checkpoints let the next
    # run continue a large first-time enumeration.
    Update-ARDirectorySnapshot -TimeBudgetSeconds 1500
}
