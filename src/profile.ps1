# Azure Functions PowerShell profile.
#
# This runs once per worker (cold start). We do NOT authenticate here because
# every function acquires its own tokens on demand from the managed identity
# endpoint (see Get-ARGraphToken / Get-ARStorageToken in the AutoRevocate module).
#
# Keep this file lean: anything expensive here is paid on every cold start.

$ErrorActionPreference = 'Stop'

# Import the app module EXPLICITLY. The worker puts wwwroot/Modules on
# PSModulePath, but PowerShell's command auto-discovery cannot see commands in a
# module whose manifest exports with a wildcard (FunctionsToExport = '*'), so it
# never auto-imports it and every function fails with 'Initialize-ARTables is
# not recognized'. Importing by path here is deterministic on every worker.
Import-Module (Join-Path $PSScriptRoot 'Modules/AutoRevocate/AutoRevocate.psd1') -Force -ErrorAction Stop

# NOTE: StrictMode is intentionally NOT enabled. The tool works with dynamic
# JSON from Microsoft Graph where properties are conditionally present, and it
# reads optional properties defensively via $obj.PSObject.Properties['x'].Value.
# Under StrictMode that idiom throws when a property is absent, so strict mode
# would break normal operation.
