# Cores da identidade DICON, para dot-source em scripts PowerShell.
# Ex.:  . "$PSScriptRoot\..\assets\marca\dicon-cores.ps1" ; $DiconCor.azul_je

$Global:DiconCor = [pscustomobject]@{
    # azuis
    azul_je         = '#123FA8'
    azul_je_escuro  = '#6E9BFF'
    azul_profundo   = '#0A1E4D'
    azul_ambiente   = '#E7ECF8'
    # veredito (claro / escuro)
    viavel          = '#1B7F3B'
    viavel_escuro   = '#4FC177'
    ressalva        = '#B77F00'
    ressalva_escuro = '#E8B93E'
    inviavel        = '#BC352A'
    inviavel_escuro = '#E8695C'
    # neutros
    grafite         = '#14181F'
    aco             = '#5C6472'
    papel           = '#F4F5F8'
    linha           = '#C9CFDB'
    # herança (só filete)
    amarelo         = '#F2C200'
    verde           = '#009C3B'
}
