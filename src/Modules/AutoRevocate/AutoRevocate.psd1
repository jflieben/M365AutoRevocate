@{
    RootModule        = 'AutoRevocate.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b2d4f1a6-9c3e-4b77-8a1d-2f6c7e0a9d51'
    Author            = 'Jos Lieben'
    CompanyName       = 'Lieben Consultancy'
    Copyright         = '(c) Lieben Consultancy. All rights reserved.'
    Description       = 'Core logic for M365AutoRevocate: Graph change-notification driven cleanup of deleted users (OneDrive unshare, artifact hand-off) using managed identity only.'
    PowerShellVersion = '7.4'
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
