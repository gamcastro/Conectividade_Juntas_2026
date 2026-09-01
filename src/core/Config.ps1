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

# Grava/mescla o bloco iperf3 em config/ambiente.json (preserva ping/totalizacao).
# Usado pela tela de Administracao. Devolve o caminho do arquivo salvo.
function Save-ConfigAmbiente {
    param(
        [Parameter(Mandatory)] [string] $Servidor,
        [int] $Porta   = 5201,
        [int] $Duracao = 10
    )
    $dir  = Join-Path $Global:RaizApp 'config'
    $alvo = Join-Path $dir 'ambiente.json'

    $base = $null
    try { $base = Get-Config 'ambiente' } catch { }
    if (-not $base) {
        $base = [pscustomobject]@{
            ping        = [pscustomobject]@{ alvo = $Servidor; amostras = 20 }
            totalizacao = [pscustomobject]@{ url = ''; navegadores = @('firefox', 'chrome'); timeout_s = 60 }
        }
    }
    $novoIperf = [pscustomobject]@{ servidor = $Servidor; porta = [int] $Porta; duracao_s = [int] $Duracao; reverso = $true }
    if ($base.PSObject.Properties['iperf3']) { $base.iperf3 = $novoIperf }
    else { $base | Add-Member -NotePropertyName iperf3 -NotePropertyValue $novoIperf -Force }

    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $base | ConvertTo-Json -Depth 8 | Set-Content -Path $alvo -Encoding UTF8
    $alvo
}
