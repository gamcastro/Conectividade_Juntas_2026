# Leitura de configuracao. Usa config\<nome>.json se existir; senao cai no
# config\<nome>.exemplo.json (util para rodar recem-clonado, sem configs reais).

# Grava texto num arquivo de forma resiliente. Usa [IO.File]::WriteAllText em
# vez de Set-Content: o provider FileSystem do PS 5.1 as vezes abre um
# StreamReader sobre o arquivo novo (farejar encoding) e estoura "O fluxo nao
# era legivel" quando o antivirus esta com o handle. Retry curto p/ o lock.
function Write-TextoArquivo {
    param(
        [Parameter(Mandatory)] [string] $Caminho,
        [string] $Conteudo = '',
        [switch] $ComBom
    )
    $pai = Split-Path $Caminho -Parent
    if ($pai -and -not (Test-Path $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
    $enc = [Text.UTF8Encoding]::new([bool] $ComBom)
    for ($i = 1; $i -le 6; $i++) {
        try { [IO.File]::WriteAllText($Caminho, [string] $Conteudo, $enc); return }
        catch { if ($i -eq 6) { throw }; Start-Sleep -Milliseconds 300 }
    }
}

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
        [int] $Duracao = 10,
        [string] $MapsKey,                 # chave da Maps Static API (opcional)
        # Quais dos 3 itens do semaforo do overlay de checagem aparecem (so'
        # visibilidade -- nao desliga a medicao em si, ver Reset-OverlayCheck).
        [bool] $OverlayRedeLocal  = $true,
        [bool] $OverlayVpn        = $true,
        [bool] $OverlayTotalizacao = $true
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

    if ($PSBoundParameters.ContainsKey('MapsKey')) {
        $gm = [pscustomobject]@{ static_key = ([string] $MapsKey).Trim() }
        if ($base.PSObject.Properties['google_maps']) { $base.google_maps = $gm }
        else { $base | Add-Member -NotePropertyName google_maps -NotePropertyValue $gm -Force }
    }

    $novoOverlay = [pscustomobject]@{
        rede_local  = [bool] $OverlayRedeLocal
        vpn         = [bool] $OverlayVpn
        totalizacao = [bool] $OverlayTotalizacao
    }
    if ($base.PSObject.Properties['overlay_passos']) { $base.overlay_passos = $novoOverlay }
    else { $base | Add-Member -NotePropertyName overlay_passos -NotePropertyValue $novoOverlay -Force }

    # nao persiste google_oauth em ambiente.json: e camada do exemplo/pacote (a
    # credencial vem de la). Se veio do fallback Get-Config, tira antes de gravar.
    if ($base.PSObject.Properties['google_oauth']) { $base.PSObject.Properties.Remove('google_oauth') }

    Write-TextoArquivo -Caminho $alvo -Conteudo ($base | ConvertTo-Json -Depth 8)
    $alvo
}
