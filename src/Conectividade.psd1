@{
    RootModule        = 'Conectividade.psm1'
    ModuleVersion     = '0.6.98'
    GUID              = 'b3f1c2a4-5d6e-4f70-8a91-0c2d3e4f5a6b'
    Author            = 'TRE-MA / STI'
    CompanyName       = 'Tribunal Regional Eleitoral do Maranhao'
    Copyright         = '(c) 2026 TRE-MA'
    Description       = 'DICON - Diagnostico de Conectividade. Viabilidade de infraestrutura de TIC para as Juntas Eleitorais Especiais 2026 (TRE-MA).'
    PowerShellVersion = '5.1'

    # Todas as funcoes Verbo-Substantivo (o .psm1 ja restringe com Export-ModuleMember '*-*').
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
