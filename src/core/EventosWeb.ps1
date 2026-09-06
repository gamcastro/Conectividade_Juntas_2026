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
function Add-EventoWeb {
    param([Parameter(Mandatory)] [string] $Tipo, $Local)
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
        $nome = '{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $Tipo
        Write-TextoArquivo -Caminho (Join-Path (Get-PastaEventosWeb) $nome) -Conteudo (([pscustomobject] $obj) | ConvertTo-Json -Depth 5)
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
# anterior ainda roda, sai.
$Global:EnvioWebState = $null
function Start-EnvioWebAssincrono {
    if (-not (Test-CheckinWebLigado)) { return }

    if ($Global:EnvioWebState) {
        if ($Global:EnvioWebState.Handle.IsCompleted) {
            try { $Global:EnvioWebState.PS.EndInvoke($Global:EnvioWebState.Handle) | Out-Null } catch { }
            try { $Global:EnvioWebState.PS.Dispose(); $Global:EnvioWebState.RS.Dispose() } catch { }
            $Global:EnvioWebState = $null
        } else {
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
