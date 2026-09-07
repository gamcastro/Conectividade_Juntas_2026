# Check-in ao vivo do tecnico para o DICON Web (docs/dicon-web-plano.md, Fase 1).
#
# TUDO "melhor esforco": nada aqui pode travar a tela nem interromper um
# diagnostico. Os eventos sao gravados como arquivos locais (instantaneo, sem
# rede) numa fila 'eventos\pendentes\'; o envio ao Apps Script (acoes 'checkin'
# e 'evento', ver apps-script/Codigo.gs > executar) roda num runspace de
# segundo plano -- no login, a cada 5 min (heartbeat) e no "Atualizar dados".
# Sem internet / sem conta Google -> os arquivos ficam na fila e sobem depois.

function Test-CheckinWebLigado {
    if ($Global:ModoTeste) { return $false }   # testes da GUI nao disparam check-in real
    try {
        $cfg = Get-Config 'envio'
        if ($cfg -and $cfg.PSObject.Properties['checkin_web']) { return [bool] $cfg.checkin_web }
    } catch { }
    return $true   # padrao: ligado
}

function Get-PastaEventosWeb {
    $p = Join-Path $Global:RaizApp 'eventos\pendentes'
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

# Payload comum de identificacao do tecnico/maquina. Montado SEMPRE na thread da
# UI (le $Global:SessaoAtual / $Global:RoteiroAtual, que nao existem no runspace).
function New-CheckinPayloadWeb {
    $email = ''
    try { $email = [string] (Get-EmailGoogleConectado) } catch { }
    @{
        tecnico      = [string] $Global:SessaoAtual.tecnico_nome
        email        = $email
        versao_dicon = [string] $Global:VersaoApp
        maquina      = [string] $env:COMPUTERNAME
        roteiro      = $(if ($Global:RoteiroAtual) { [string] $Global:RoteiroAtual.rotulo } else { '' })
    }
}

# Enfileira um evento (so' escreve arquivo -- sem rede). -Tipo:
#   abriu_app | iniciou_diagnostico | rodou_checagem | salvou | transmitiu |
#   finalizou | abandonou
# -Sincrono: tenta MANDAR na hora (timeout curto) antes de enfileirar -- pro
#   fechamento da janela, onde o runspace de fundo morreria antes de enviar.
function Add-EventoWeb {
    param([Parameter(Mandatory)] [string] $Tipo, $Local, [switch] $Sincrono)
    if (-not (Test-CheckinWebLigado)) { return }
    try {
        if (-not $Local -and $Tipo -ne 'abriu_app') {
            try { $Local = Get-LocalDoAssistente } catch { $Local = $null }
        }
        $base = New-CheckinPayloadWeb
        $obj = [ordered]@{
            id_evento    = [guid]::NewGuid().ToString()
            hora_cliente = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')
            tipo         = $Tipo
            tecnico      = $base.tecnico
            email        = $base.email
            versao_dicon = $base.versao_dicon
            maquina      = $base.maquina
            roteiro      = $base.roteiro
            local_id     = $(if ($Local) { [string] $Local.id } else { '' })
            zona         = $(if ($Local) { [string] $Local.zona_eleitoral } else { '' })
            municipio    = $(if ($Local) { [string] $Local.municipio_termo } else { '' })
            tipo_local   = $(if ($Local) { [string] $Local.tipo } else { '' })
            detalhe      = $(if ($Local -and $Local.nome) { [string] $Local.nome } else { '' })
        }

        if ($Sincrono) {
            # Best-effort, sem travar o fechamento por muito tempo. Se enviar, nao
            # enfileira; se falhar (sem rede), cai na fila pro proximo flush.
            try {
                $resp = Invoke-FuncaoAppsScript -Acao 'evento' -Payload ([pscustomobject] $obj) -TimeoutS 6
                if ($resp -and ([string] $resp.status) -eq 'ok') { return }
            } catch { }
        }

        $nome = '{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $Tipo
        Write-TextoArquivo -Caminho (Join-Path (Get-PastaEventosWeb) $nome) -Conteudo (([pscustomobject] $obj) | ConvertTo-Json -Depth 5)
        # Empurra a fila JA (fire-and-forget, nao empilha) -- senao o evento so'
        # sairia no proximo heartbeat de 5 min e o "ao vivo" da console ficaria
        # muito atrasado. 'abriu_app' ja tem o seu envio no fluxo de login; no
        # -Sincrono a janela esta' fechando, entao o runspace nem roda.
        if ($Tipo -ne 'abriu_app' -and -not $Sincrono) { try { Start-EnvioWebAssincrono } catch { } }
    } catch {
        try { Write-Log "Evento web '$Tipo' nao enfileirado: $_" -Nivel Aviso } catch { }
    }
}

# Envia tudo da fila de eventos. Roda DENTRO de um runspace de segundo plano
# (Start-EnvioWebAssincrono) ou do trabalho de "Atualizar dados" -- nunca direto
# na UI. Sucesso -> apaga o arquivo; falha de rede -> mantem e para; arquivo com
# mais de 7 dias e' descartado. Nao lanca.
function Send-EventosWebPendentes {
    if (-not (Test-CheckinWebLigado)) { return 0 }
    $pasta = Join-Path $Global:RaizApp 'eventos\pendentes'
    if (-not (Test-Path $pasta)) { return 0 }
    $arqs = @(Get-ChildItem -Path $pasta -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $arqs.Count) { return 0 }

    $enviados = 0
    foreach ($a in $arqs) {
        if (((Get-Date) - $a.LastWriteTime).TotalDays -gt 7) {
            Remove-Item $a.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $obj = $null
        try { $obj = Get-Content $a.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        try {
            $resp = Invoke-FuncaoAppsScript -Acao 'evento' -Payload $obj -TimeoutS 20
            if ($resp -and ([string] $resp.status) -eq 'ok') {
                Remove-Item $a.FullName -Force -ErrorAction SilentlyContinue
                $enviados++
            }
        } catch {
            break   # sem internet / CONECTAR_GOOGLE / etc -> tenta na proxima
        }
    }
    if ($enviados) { try { Write-Log "Check-in web: $enviados evento(s) enviado(s)." -Nivel Info } catch { } }
    return $enviados
}

# Dispara, num runspace de segundo plano (fire-and-forget), o heartbeat
# ('checkin') + o flush da fila de eventos. Nao bloqueia a UI. Nao empilha: se o
# anterior ainda roda, re-tenta em ~3 s (one-shot) -- senao um 'iniciou_diagnostico'
# disparado logo apos o login ficaria esperando o heartbeat de 5 min pra sair, e
# o "ao vivo" / o ponto pulsante do mapa apareceriam com minutos de atraso.
$Global:EnvioWebState = $null
$Global:EnvioWebRetryTimer = $null
function Start-EnvioWebAssincrono {
    if (-not (Test-CheckinWebLigado)) { return }

    if ($Global:EnvioWebState) {
        if ($Global:EnvioWebState.Handle.IsCompleted) {
            try { $Global:EnvioWebState.PS.EndInvoke($Global:EnvioWebState.Handle) | Out-Null } catch { }
            try { $Global:EnvioWebState.PS.Dispose(); $Global:EnvioWebState.RS.Dispose() } catch { }
            $Global:EnvioWebState = $null
        } else {
            if (-not $Global:EnvioWebRetryTimer) {
                try {
                    $t = [Windows.Threading.DispatcherTimer]::new()
                    $t.Interval = [TimeSpan]::FromSeconds(3)
                    $t.Add_Tick({
                        try { $Global:EnvioWebRetryTimer.Stop() } catch { }
                        $Global:EnvioWebRetryTimer = $null
                        try { Start-EnvioWebAssincrono } catch { }
                    })
                    $Global:EnvioWebRetryTimer = $t
                    $t.Start()
                } catch { }
            }
            return
        }
    }
    if (-not $Global:SessaoAtual) { return }

    $checkin = $null
    try { $checkin = New-CheckinPayloadWeb } catch { }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('RaizAppW', $Global:RaizApp)
        $rs.SessionStateProxy.SetVariable('ArquivoLogW', $Global:ArquivoLog)
        $rs.SessionStateProxy.SetVariable('CheckinW', $checkin)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void] $ps.AddScript({
            try {
                Import-Module (Join-Path $RaizAppW 'src\Conectividade.psd1') -Force -ErrorAction Stop
                $Global:RaizApp    = $RaizAppW
                $Global:ArquivoLog = $ArquivoLogW
                if ($CheckinW) {
                    try { Invoke-FuncaoAppsScript -Acao 'checkin' -Payload $CheckinW -TimeoutS 15 | Out-Null } catch { }
                }
                try { Send-EventosWebPendentes | Out-Null } catch { }
            } catch { }
        })
        $h = $ps.BeginInvoke()
        $Global:EnvioWebState = @{ PS = $ps; RS = $rs; Handle = $h }
    } catch {
        try { Write-Log "Check-in web (envio) nao iniciou: $_" -Nivel Aviso } catch { }
    }
}

# Heartbeat: a cada 5 min enquanto o DICON esta aberto. Iniciado no login,
# parado ao trocar de usuario.
$Global:HeartbeatWebTimer = $null
function Start-HeartbeatWeb {
    if (-not (Test-CheckinWebLigado)) { return }
    Stop-HeartbeatWeb
    try {
        $t = [Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [TimeSpan]::FromMinutes(5)
        $t.Add_Tick({ try { Start-EnvioWebAssincrono } catch { } })
        $t.Start()
        $Global:HeartbeatWebTimer = $t
    } catch { }
}
function Stop-HeartbeatWeb {
    if ($Global:HeartbeatWebTimer) {
        try { $Global:HeartbeatWebTimer.Stop() } catch { }
        $Global:HeartbeatWebTimer = $null
    }
}

# ---------------------------------------------------------------------------
# Envio do PDF do relatorio individual para o Drive da coordenacao (DICON Web
# Fase 1, item 4). Best-effort: roda num runspace proprio, nao bloqueia a UI,
# nunca lanca. O servidor (acao 'pdf.relatorio' -> webUploadPdfRelatorio) sobe
# o arquivo em DICON/relatorios/ com o token de servico e grava pdf_url na
# linha do Local na aba Resultados.
function Test-PdfWebLigado {
    if ($Global:ModoTeste) { return $false }
    try {
        $cfg = Get-Config 'envio'
        if ($cfg -and $cfg.PSObject.Properties['pdf_web']) { return [bool] $cfg.pdf_web }
    } catch { }
    return $true
}

$Global:PdfWebState = $null
function Start-EnvioPdfRelatorioWeb {
    param(
        [Parameter(Mandatory)] [string] $LocalId,
        [Parameter(Mandatory)] [string] $Caminho
    )
    if (-not (Test-PdfWebLigado)) { return }
    if (-not $LocalId -or -not (Test-Path $Caminho)) { return }

    # le o arquivo AQUI (thread da UI): bytes + guarda de tamanho.
    $b64 = $null
    try {
        $fi = Get-Item $Caminho -ErrorAction Stop
        if ($fi.Length -gt 9MB) {
            try { Write-Log ("Relatorio PDF ({0} MB) grande demais para a console; envio pulado." -f [math]::Round($fi.Length / 1MB, 1)) -Nivel Aviso } catch { }
            return
        }
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fi.FullName))
    } catch { return }
    if (-not $b64) { return }

    $payload = @{
        local_id = [string] $LocalId
        tecnico  = [string] $Global:SessaoAtual.tecnico_nome
        nome     = ('{0}.pdf' -f ([string] $LocalId -replace '[^A-Za-z0-9_.-]+', '_'))
        b64      = $b64
    }

    # nao empilha: se ja ha um envio rodando, deixa quieto (o proximo export reenvia).
    if ($Global:PdfWebState) {
        if ($Global:PdfWebState.Handle.IsCompleted) {
            try { $Global:PdfWebState.PS.EndInvoke($Global:PdfWebState.Handle) | Out-Null } catch { }
            try { $Global:PdfWebState.PS.Dispose(); $Global:PdfWebState.RS.Dispose() } catch { }
            $Global:PdfWebState = $null
        } else { return }
    }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('RaizAppW', $Global:RaizApp)
        $rs.SessionStateProxy.SetVariable('ArquivoLogW', $Global:ArquivoLog)
        $rs.SessionStateProxy.SetVariable('PayloadW', $payload)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void] $ps.AddScript({
            try {
                Import-Module (Join-Path $RaizAppW 'src\Conectividade.psd1') -Force -ErrorAction Stop
                $Global:RaizApp    = $RaizAppW
                $Global:ArquivoLog = $ArquivoLogW
                try {
                    $r = Invoke-FuncaoAppsScript -Acao 'pdf.relatorio' -Payload $PayloadW -TimeoutS 60
                    if ($r -and $r.status -eq 'ok') { try { Write-Log "Relatorio PDF enviado a console: $($r.url)" -Nivel Ok } catch { } }
                } catch { }
            } catch { }
        })
        $h = $ps.BeginInvoke()
        $Global:PdfWebState = @{ PS = $ps; RS = $rs; Handle = $h }
    } catch {
        try { Write-Log "Envio do PDF do relatorio nao iniciou: $_" -Nivel Aviso } catch { }
    }
}

# ---------------------------------------------------------------------------
# Sync do formulario do GEL + fotos (Escopo 2 da tela Coordenacao). O GEL
# (data\vistoria-gel\<id>.json) e as fotos (data\vistoria-gel\<id>\*.jpg) ficavam
# so' na maquina onde foram anexados. Aqui sobem/descem pelo backend:
#   - 'gel.enviar'  -> aba GEL da planilha de Resultados + Drive da coordenacao
#   - 'gel.obter'   -> devolve o JSON + as fotos (base64)
# Ver apps-script/web/GelWeb.gs. Best-effort: nunca trava a tela, nunca lanca.
function Test-GelSyncLigado {
    if ($Global:ModoTeste) { return $false }
    try {
        $cfg = Get-Config 'envio'
        if ($cfg -and $cfg.PSObject.Properties['gel_sync']) { return [bool] $cfg.gel_sync }
    } catch { }
    return $true
}

# Sobe o GEL + fotos de um Local para o backend, num runspace proprio (nao
# bloqueia a UI). -Remover: manda apagar o anexo do servidor. Le os arquivos AQUI
# (thread da UI); guarda de tamanho total (~9 MB).
$Global:GelWebState = $null
function Start-EnvioGelWeb {
    param([Parameter(Mandatory)] [string] $LocalId, [switch] $Remover)
    if (-not (Test-GelSyncLigado)) { return }
    if ([string]::IsNullOrWhiteSpace($LocalId)) { return }

    $payload = @{
        local_id     = [string] $LocalId
        enviado_por  = ''
        remover      = [bool] $Remover
        gel_json     = ''
        fotos        = @()
    }
    try { $payload.enviado_por = [string] (Get-EmailGoogleConectado) } catch { }
    if (-not $payload.enviado_por) { $payload.enviado_por = [string] $Global:SessaoAtual.tecnico_nome }

    if (-not $Remover) {
        $g = $null
        try { $g = Get-VistoriaGel -LocalId $LocalId } catch { }
        if ($g) { try { $payload.gel_json = ($g | ConvertTo-Json -Depth 6 -Compress) } catch { } }

        $fotos = @()
        $total = 0L
        try {
            foreach ($f in @(Get-FotosGel -LocalId $LocalId)) {
                $fi = Get-Item $f -ErrorAction Stop
                $total += $fi.Length
                if ($total -gt 9MB) {
                    try { Write-Log 'Sync GEL: fotos passam de 9 MB no total; envio pulado.' -Nivel Aviso } catch { }
                    return
                }
                $fotos += @{ nome = $fi.Name; b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fi.FullName)) }
            }
        } catch { }
        $payload.fotos = $fotos
        # nada pra enviar (sem GEL e sem fotos) e nao e' remocao -> sai
        if (-not $payload.gel_json -and -not $fotos.Count) { return }
    }

    if ($Global:GelWebState) {
        if ($Global:GelWebState.Handle.IsCompleted) {
            try { $Global:GelWebState.PS.EndInvoke($Global:GelWebState.Handle) | Out-Null } catch { }
            try { $Global:GelWebState.PS.Dispose(); $Global:GelWebState.RS.Dispose() } catch { }
            $Global:GelWebState = $null
        } else { return }
    }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('RaizAppW', $Global:RaizApp)
        $rs.SessionStateProxy.SetVariable('ArquivoLogW', $Global:ArquivoLog)
        $rs.SessionStateProxy.SetVariable('PayloadW', $payload)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void] $ps.AddScript({
            try {
                Import-Module (Join-Path $RaizAppW 'src\Conectividade.psd1') -Force -ErrorAction Stop
                $Global:RaizApp    = $RaizAppW
                $Global:ArquivoLog = $ArquivoLogW
                try {
                    $r = Invoke-FuncaoAppsScript -Acao 'gel.enviar' -Payload $PayloadW -TimeoutS 60
                    if ($r -and $r.status -eq 'ok') {
                        $msg = if ($PayloadW.remover) { 'Anexo GEL removido da console.' }
                               else { "Formulario GEL sincronizado com a console ($([int] $r.fotos) foto(s))." }
                        try { Write-Log $msg -Nivel Ok } catch { }
                    }
                } catch { }
            } catch { }
        })
        $h = $ps.BeginInvoke()
        $Global:GelWebState = @{ PS = $ps; RS = $rs; Handle = $h }
    } catch {
        try { Write-Log "Sync do GEL nao iniciou: $_" -Nivel Aviso } catch { }
    }
}

# Puxa do backend o GEL + fotos de um Local e grava em data\vistoria-gel\<id>\.
# SINCRONO (chamado de dentro de um runspace: Sync-Resultados / Start-TarefaRede).
# Nao sobrescreve um anexo LOCAL ja existente, a menos que -Forcar. Nao lanca.
# Devolve $true se baixou algo.
function Get-VistoriaGelRemoto {
    param([Parameter(Mandatory)] [string] $LocalId, [switch] $Forcar)
    if (-not (Test-GelSyncLigado)) { return $false }
    if ([string]::IsNullOrWhiteSpace($LocalId)) { return $false }

    if (-not $Forcar) {
        $ja = $null
        try { $ja = Get-VistoriaGel -LocalId $LocalId } catch { }
        if ($ja) { return $false }   # ja tem anexo local -- nao mexe
    }

    $resp = $null
    try { $resp = Invoke-FuncaoAppsScript -Acao 'gel.obter' -Payload @{ local_id = [string] $LocalId } -TimeoutS 45 }
    catch {
        $m = "$_"
        if ($m -match 'acao desconhecida' -or $m -match 'gel\.obter') { return $false }  # servidor sem o recurso
        return $false
    }
    if (-not $resp -or $resp.erro) { return $false }

    $baixou = $false
    $idSan = [string] $LocalId -replace '[^\w\-]', '_'
    $dir   = Join-Path (Get-PastaDados) 'vistoria-gel'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($resp.gel_json) {
        $obj = $null
        try { $obj = $resp.gel_json | ConvertFrom-Json } catch { }
        if ($obj) {
            try {
                Write-TextoArquivo -Caminho (Join-Path $dir ($idSan + '.json')) -Conteudo ($obj | ConvertTo-Json -Depth 8)
                $baixou = $true
            } catch { }
        }
    }

    $fotos = @($resp.fotos)
    if ($fotos.Count) {
        $fdir = Join-Path $dir $idSan
        if (-not (Test-Path $fdir)) { New-Item -ItemType Directory -Path $fdir -Force | Out-Null }
        # servidor manda o conjunto atual -> limpa o que houver e regrava
        try { Get-ChildItem -Path $fdir -Filter '*.jpg' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
        $n = 0
        foreach ($ft in $fotos) {
            if (-not $ft.b64) { continue }
            $n++
            $nome = [string] $ft.nome
            if (-not $nome -or $nome -notmatch '\.(jpg|jpeg|png)$') { $nome = 'foto-{0:00}.jpg' -f $n }
            try { [IO.File]::WriteAllBytes((Join-Path $fdir $nome), [Convert]::FromBase64String([string] $ft.b64)); $baixou = $true } catch { }
        }
    }

    if ($baixou) { try { Write-Log ("GEL do local {0} baixado da console ({1} foto(s))." -f $LocalId, $fotos.Count) -Nivel Info } catch { } }
    return $baixou
}
