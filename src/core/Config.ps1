# Leitura de configuracao. Usa config\<nome>.json se existir; senao cai no
# config\<nome>.exemplo.json (util para rodar recem-clonado, sem configs reais).

function Get-Config {
    param(
        [string] $Nome
    )
    if ([string]::IsNullOrWhiteSpace($Nome)) {
        throw "Get-Config: informe o nome da configuracao (ex.: 'limiares')."
    }

    $dir     = Join-Path $Global:RaizApp 'config'
    $real    = Join-Path $dir "$Nome.json"
    $exemplo = Join-Path $dir "$Nome.exemplo.json"

    $caminho = if (Test-Path $real) { $real } elseif (Test-Path $exemplo) { $exemplo } else { $null }
    if (-not $caminho) {
        throw "Configuracao '$Nome' nao encontrada em $dir (nem .json nem .exemplo.json)."
    }

    Get-Content -Path $caminho -Raw -Encoding UTF8 | ConvertFrom-Json
}
