# Limiares de decisao. Vem da planilha de config via ?recurso=limiares, cacheados
# em data/limiares.json. O admin edita e salva (POST autenticado por PIN).
#
# Formato NESTED (v0.6.67+): limiares por MEIO (lan / wifi_local / celular) x
# CENARIO (sem_vpn / com_vpn). Ver config/limiares.exemplo.json e
# docs/limiares-referencia.md.
#   - perfis.lan / perfis.celular : valores absolutos por cenario.
#   - perfis.wifi_local           : NAO guarda valores; herda da LAN + 'folga'
#                                   (aditivo p/ latencia/jitter/perda/web,
#                                   haircut %% p/ banda) + flags 'ativos'.
#   - orcamento_vpn               : semeia o COM VPN de LAN/Celular (na tela do
#                                   admin); nao entra na resolucao em runtime.
# Get-PerfilLimiares devolve o shape PLANO que Invoke-MotorDecisao consome.

# Metadados das metricas (ordem + direcao + em quais cenarios existe).
$script:LimiarMetricas = @(
    @{ metrica = 'latencia_ms';         direcao = 'max'; cenarios = @('sem_vpn', 'com_vpn') }
    @{ metrica = 'jitter_ms';           direcao = 'max'; cenarios = @('sem_vpn', 'com_vpn') }
    @{ metrica = 'perda_percentual';    direcao = 'max'; cenarios = @('sem_vpn', 'com_vpn') }
    @{ metrica = 'banda_download_mbps'; direcao = 'min'; cenarios = @('sem_vpn', 'com_vpn'); pct = 'banda_download_pct' }
    @{ metrica = 'banda_upload_mbps';   direcao = 'min'; cenarios = @('sem_vpn', 'com_vpn'); pct = 'banda_upload_pct' }
    @{ metrica = 'carregamento_web_s';  direcao = 'max'; cenarios = @('com_vpn') }
)

function Get-LimiarMetricas { $script:LimiarMetricas }

# $true se o doc ja esta no formato NESTED (por meio x cenario).
function Test-LimiaresNested {
    param($Doc)
    [bool] ($Doc -and $Doc.PSObject.Properties['perfis'] -and $Doc.perfis)
}

function Sync-Limiares {
    Write-Log 'Baixando limiares...' -Nivel Info
    $resp = Invoke-RecursoWebApp -Recurso 'limiares'
    if (-not $resp.limiares) { throw "Resposta de 'limiares' sem dados." }
    $novo = @($resp.limiares) | Select-Object -First 1

    # Web App ainda no formato antigo (plano): NAO deixa sobrescrever limiares
    # locais que ja estao no formato novo (por meio x cenario) - vindos de um
    # "Salvar limiares" do admin ou do config/limiares.exemplo.json novo.
    if (-not (Test-LimiaresNested $novo) -and (Test-LimiaresNested (Get-LimiaresConfig))) {
        Write-Log 'Web App ainda no formato antigo de limiares - mantendo os limiares locais (por meio x cenario).' -Nivel Aviso
        return (Get-LimiaresConfig)
    }

    Write-CacheJson -Nome 'limiares.json' -Campo 'limiares' -Itens $novo -Origem "recurso=limiares ($($resp.origem))"
    return $novo
}

# Bloco 'folga' padrao do wifi_local (usado na migracao do formato antigo).
function New-FolgaWifiPadrao {
    [pscustomobject]@{
        latencia_ms = 10; jitter_ms = 5; perda_percentual = 1
        banda_download_pct = -20; banda_upload_pct = -20; carregamento_web_s = 3
    }
}
function New-OrcamentoVpnPadrao {
    [pscustomobject]@{
        latencia_ms = 30; jitter_ms = 10; perda_percentual = 1
        banda_download_pct = -30; banda_upload_pct = -30
    }
}

# Recebe o doc bruto (nested novo OU plano antigo) e devolve sempre o nested.
function ConvertTo-PerfisLimiares {
    param($Doc)
    if ($null -eq $Doc) { return $Doc }
    if ($Doc.PSObject.Properties['perfis'] -and $Doc.perfis) { return $Doc }

    # formato plano antigo { latencia_ms:{viavel_ate,ressalva_ate,ativo}, ... }
    $flat = $Doc
    $mk = {
        param([bool] $ComWeb)
        $o = [ordered]@{}
        foreach ($m in $script:LimiarMetricas) {
            if (-not $ComWeb -and $m.metrica -eq 'carregamento_web_s') { continue }
            $p = $flat.PSObject.Properties[$m.metrica]
            if ($p) { $o[$m.metrica] = $p.Value }
        }
        [pscustomobject] $o
    }
    $ativosSem = [pscustomobject]@{ latencia_ms = $true; jitter_ms = $true; perda_percentual = $true; banda_download_mbps = $true; banda_upload_mbps = $true }
    $ativosCom = [pscustomobject]@{ latencia_ms = $true; jitter_ms = $true; perda_percentual = $true; banda_download_mbps = $true; banda_upload_mbps = $true; carregamento_web_s = $true }
    $lanSem = & $mk $false
    $lanCom = & $mk $true
    [pscustomobject]@{
        _comentario   = 'migrado do formato plano antigo (v<=0.6.66)'
        orcamento_vpn = New-OrcamentoVpnPadrao
        perfis        = [pscustomobject]@{
            lan        = [pscustomobject]@{ sem_vpn = $lanSem; com_vpn = $lanCom }
            celular    = [pscustomobject]@{ sem_vpn = $lanSem; com_vpn = $lanCom }
            wifi_local = [pscustomobject]@{ folga = (New-FolgaWifiPadrao); ativos = [pscustomobject]@{ sem_vpn = $ativosSem; com_vpn = $ativosCom } }
        }
    }
}

# Doc NESTED (sempre). Prioridade:
#   1) cache data/limiares.json SE ja estiver no formato novo (Web App novo ou
#      "Salvar limiares" do admin) - assim as edicoes centrais valem;
#   2) config/limiares.json|.exemplo.json SE ja for o formato novo - assim um
#      cache antigo (Web App v1) nao rebaixa os pisos ANATEL do pacote;
#   3) migra o que houver (cache tem preferencia sobre o exemplo).
# O Write-CacheJson embrulha o payload num array; desembrulhamos aqui.
function Get-LimiaresConfig {
    $arq = Join-Path (Get-PastaDados) 'limiares.json'
    $cache = $null
    if (Test-Path $arq) {
        try {
            $doc = Get-Content -Path $arq -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $doc.limiares) { $cache = @($doc.limiares) | Select-Object -First 1 }
        } catch {
            Write-Log "Cache de limiares corrompido, usando o local: $_" -Nivel Aviso
        }
    }
    if (Test-LimiaresNested $cache) { return $cache }

    $local = $null
    try { $local = Get-Config 'limiares' } catch { }
    if (Test-LimiaresNested $local) { return $local }

    if ($null -ne $cache) { return ConvertTo-PerfisLimiares $cache }
    return ConvertTo-PerfisLimiares $local
}

# Le uma flag booleana de um objeto, com default (StrictMode-safe).
function Get-BoolProp {
    param($Obj, [string] $Nome, [bool] $Padrao = $true)
    if ($null -eq $Obj) { return $Padrao }
    $p = $Obj.PSObject.Properties[$Nome]
    if (-not $p) { return $Padrao }
    return [bool] $p.Value
}
function Get-NumProp {
    param($Obj, [string] $Nome, $Padrao = $null)
    if ($null -eq $Obj) { return $Padrao }
    $p = $Obj.PSObject.Properties[$Nome]
    if (-not $p -or $null -eq $p.Value) { return $Padrao }
    try { return [double] $p.Value } catch { return $Padrao }
}

# Perfil PLANO (shape de Invoke-MotorDecisao) para um meio x cenario.
#   { latencia_ms:{viavel_ate,ressalva_ate,ativo}, ...,
#     banda_download_mbps:{viavel_min,ressalva_min,ativo}, ... }
# carregamento_web_s sempre presente; em sem_vpn vem inativo (nunca medido).
function Get-PerfilLimiares {
    param(
        [ValidateSet('lan', 'wifi_local', 'celular')] [string] $Meio = 'lan',
        [ValidateSet('sem_vpn', 'com_vpn')]           [string] $Cenario = 'com_vpn'
    )
    $doc    = Get-LimiaresConfig
    $perfis = $doc.perfis

    if ($Meio -eq 'wifi_local') {
        $base   = Get-PerfilLimiares -Meio 'lan' -Cenario $Cenario
        $folga  = if ($perfis.wifi_local) { $perfis.wifi_local.folga } else { New-FolgaWifiPadrao }
        $ativosC = if ($perfis.wifi_local -and $perfis.wifi_local.ativos) { $perfis.wifi_local.ativos.$Cenario } else { $null }
        $out = [ordered]@{}
        foreach ($m in $script:LimiarMetricas) {
            if ($m.cenarios -notcontains $Cenario) {
                $out[$m.metrica] = [pscustomobject]@{ viavel_ate = $null; ressalva_ate = $null; ativo = $false }
                continue
            }
            $ativo = Get-BoolProp $ativosC $m.metrica $true
            $b = $base.($m.metrica)
            if ($m.direcao -eq 'min') {
                $fac = 1 + ((Get-NumProp $folga $m.pct 0) / 100)
                $out[$m.metrica] = [pscustomobject]@{
                    viavel_min   = [math]::Round(([double] $b.viavel_min)   * $fac, 2)
                    ressalva_min = [math]::Round(([double] $b.ressalva_min) * $fac, 2)
                    ativo        = $ativo
                }
            } else {
                $f = Get-NumProp $folga $m.metrica 0
                $out[$m.metrica] = [pscustomobject]@{
                    viavel_ate   = [math]::Round(([double] $b.viavel_ate)   + $f, 2)
                    ressalva_ate = [math]::Round(([double] $b.ressalva_ate) + $f, 2)
                    ativo        = $ativo
                }
            }
        }
        return [pscustomobject] $out
    }

    # lan / celular: absoluto
    $src = if ($perfis.$Meio) { $perfis.$Meio.$Cenario } else { $null }
    $out = [ordered]@{}
    foreach ($m in $script:LimiarMetricas) {
        if ($m.cenarios -notcontains $Cenario) {
            $out[$m.metrica] = [pscustomobject]@{ viavel_ate = $null; ressalva_ate = $null; ativo = $false }
            continue
        }
        $o = if ($src) { $p = $src.PSObject.Properties[$m.metrica]; if ($p) { $p.Value } else { $null } } else { $null }
        $ativo = Get-BoolProp $o 'ativo' $true
        if ($m.direcao -eq 'min') {
            $out[$m.metrica] = [pscustomobject]@{
                viavel_min   = Get-NumProp $o 'viavel_min'   $null
                ressalva_min = Get-NumProp $o 'ressalva_min' $null
                ativo        = $ativo
            }
        } else {
            $out[$m.metrica] = [pscustomobject]@{
                viavel_ate   = Get-NumProp $o 'viavel_ate'   $null
                ressalva_ate = Get-NumProp $o 'ressalva_ate' $null
                ativo        = $ativo
            }
        }
    }
    return [pscustomobject] $out
}

# Envia os limiares (doc NESTED) para a planilha. Retorna 'ok'|'negado'|'erro:<msg>'.
function Save-Limiares {
    param(
        [Parameter(Mandatory)] $Limiares,
        [Parameter(Mandatory)] [string] $Pin
    )
    $cfg = Get-Config 'juntas'
    $endpoint = $cfg.endpoint
    if ([string]::IsNullOrWhiteSpace($endpoint) -or $endpoint -like '*COLOQUE_O_ID*') {
        return 'erro:endpoint do Web App nao configurado'
    }

    $corpo = @{ acao = 'limiares.salvar'; pin = $Pin; limiares = $Limiares } | ConvertTo-Json -Depth 12
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Body $corpo `
                                  -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
    } catch {
        return "erro:$_"
    }

    switch ($resp.status) {
        'ok'     {
            Write-CacheJson -Nome 'limiares.json' -Campo 'limiares' -Itens $Limiares -Origem 'salvo pelo admin'
            return 'ok'
        }
        'negado' { return 'negado' }
        default  { return "erro:$($resp.erro)" }
    }
}

# Grava so o cache local (sem POST) - usado quando o Web App ainda nao foi
# reimplantado com o formato novo. Retorna o caminho do cache.
function Save-LimiaresLocal {
    param([Parameter(Mandatory)] $Limiares)
    Write-CacheJson -Nome 'limiares.json' -Campo 'limiares' -Itens $Limiares -Origem 'salvo pelo admin (local)'
    Join-Path (Get-PastaDados) 'limiares.json'
}
