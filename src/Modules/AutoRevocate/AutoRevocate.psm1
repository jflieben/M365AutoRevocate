# AutoRevocate module loader.
#
# Azure Functions auto-imports every module under the app's Modules/ folder, so
# all of these functions become available to the run.ps1 entry points. Source
# files are split by concern under ./functions and dot-sourced here.

$ErrorActionPreference = 'Stop'

Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions') -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

# Export everything shaped like an AutoRevocate function (contains "-AR").
Export-ModuleMember -Function '*-AR*'
