# Fase 1 do diagnostico: a rede LOCAL do local, ANTES de conectar a VPN do TRE.
#
#   - inventario da placa de rede cabeada (LAN): conectada? IP, mascara, gateway,
#     DNS, MAC, velocidade do enlace  -> o IP local vai no relatorio final
#   - placa wireless: existe? conectada a que SSID? redes por perto
#   - internet local: teste de velocidade Ookla (speedtest.exe --format=jsonl),
#     com velocimetro ao vivo (Write-EventoSpeedtest -> Update-Speedtest na GUI)
#   - conexao a uma rede Wi-Fi por dentro da ferramenta (netsh wlan)
#
# Depois desta fase o tecnico conecta a VPN do TRE e roda a bateria "com VPN"
# (Invoke-DiagnosticoCompleto).

# --------------------------------------------------------------- configuracao
function Get-ConfigRedeLocal {
    $def = [pscustomobject]@{
        speedtest_server_id = ''    # vazio = servidor mais proximo (auto)
        speedtest_extra_args = ''   # flags adicionais do speedtest.exe
    }
    try {
        $c = Get-Config 'rede-local'
        foreach ($p in 'speedtest_server_id', 'speedtest_extra_args') {
            if ($c.PSObject.Properties[$p] -and "$($c.$p)" -ne '') { $def.$p = $c.$p }
        }
    } catch { }
    $def
}

# Caminho do speedtest.exe (Ookla CLL). Colocado manualmente em tools\ (NAO vai
# ao repositorio). Sem ele, o teste de velocidade nao roda.
function Get-CaminhoSpeedtest {
    $cands = @(
        (Join-Path $Global:RaizApp 'tools\speedtest.exe')
        (Join-Path $Global:RaizApp 'bin\speedtest\speedtest.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command 'speedtest.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

# Repassa um evento JSONL do speedtest para a GUI (Update-Speedtest).
# Invoke SINCRONO (mantem $Evento no escopo p/ o scriptblock) mas em prioridade
# Background: Render/Input do WPF passam na frente -> janela nao "congela" no
# dilúvio de eventos, e o runspace fica no ritmo do CLI (~1 evento/100 ms).
function Write-EventoSpeedtest {
    param($Evento)
    $janela = Get-Variable -Name JanelaPrincipal -Scope Global -ErrorAction SilentlyContinue
    $dispatcher = if ($janela -and $janela.Value) { $janela.Value.Dispatcher } else { $null }
    if (-not $dispatcher) { return }
    $aplicar = { Update-Speedtest $Evento }
    if ($dispatcher.CheckAccess()) { & $aplicar }
    else { $dispatcher.Invoke([action] $aplicar, [Windows.Threading.DispatcherPriority]::Background) }
}

# Roda o speedtest.exe lendo o stdout LINHA A LINHA (JSONL). Cada linha valida
# vira um objeto; eventos de progresso vao ao vivo para a GUI. Devolve a lista
# de eventos + a saida de erro.
function Invoke-SpeedtestStreaming {
    param([string] $Caminho, [string] $Argumentos, [int] $TimeoutS = 100)
    $eventos = New-Object System.Collections.Generic.List[object]
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Caminho
    $psi.Arguments              = $Argumentos
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    # o speedtest.exe emite JSON em UTF-8 (nomes de servidor com acento).
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    $stderr = ''
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        while ($null -ne ($ln = $p.StandardOutput.ReadLine())) {
            $t = $ln.Trim()
            if ($t -eq '' -or $t[0] -ne '{') { continue }
            $obj = $null
            try { $obj = $t | ConvertFrom-Json } catch { continue }
            if ($obj -and $obj.PSObject.Properties['type']) {
                $eventos.Add($obj)
                Write-EventoSpeedtest $obj
            }
        }
        if (-not $p.WaitForExit($TimeoutS * 1000)) { try { $p.Kill() } catch { } }
        try { $stderr = $errTask.Result } catch { }
    } catch { $stderr = "$_" }
    [pscustomobject]@{ Eventos = $eventos; Erro = $stderr }
}

# --------------------------------------------------------------- placa LAN
function ConvertTo-MascaraIpv4 {
    param([int] $Prefixo)
    if ($Prefixo -lt 0 -or $Prefixo -gt 32) { return '' }
    $m = [uint32]0
    for ($i = 0; $i -lt $Prefixo; $i++) { $m = $m -bor ([uint32]1 -shl (31 - $i)) }
    '{0}.{1}.{2}.{3}' -f (($m -shr 24) -band 255), (($m -shr 16) -band 255), (($m -shr 8) -band 255), ($m -band 255)
}

function Get-AdaptadorLan {
    $vazio = [pscustomobject]@{
        presente = $false; nome = ''; descricao = ''; status = ''; conectado = $false
        ipv4 = ''; prefixo = $null; mascara = ''; gateway = ''; dns = @()
        mac = ''; velocidade_mbps = $null
    }

    $lan = $null
    try {
        $lan = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object {
                $_.InterfaceType -eq 6 -and   # 6 = ethernetCsmacd (cabo)
                $_.InterfaceDescription -notmatch 'VPN|WireGuard|OpenVPN|TAP|PANGP|AnyConnect|Fortinet|GlobalProtect|Virtual|Hyper-V|Loopback|Bluetooth'
            } |
            Sort-Object @{ Expression = { $_.Status -eq 'Up' }; Descending = $true }, ifIndex |
            Select-Object -First 1
    } catch { }
    if (-not $lan) { return $vazio }

    $o = [pscustomobject]@{
        presente = $true
        nome     = [string] $lan.Name
        descricao = [string] $lan.InterfaceDescription
        status   = [string] $lan.Status
        conectado = $false
        ipv4 = ''; prefixo = $null; mascara = ''; gateway = ''; dns = @()
        mac  = [string] $lan.MacAddress
        velocidade_mbps = $null
    }
    try { if ($lan.Speed -gt 0) { $o.velocidade_mbps = [math]::Round($lan.Speed / 1000000) } } catch { }

    if ($lan.Status -eq 'Up') {
        try {
            $ip = Get-NetIPAddress -InterfaceIndex $lan.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1
            if ($ip) {
                $o.ipv4      = [string] $ip.IPAddress
                $o.prefixo   = [int] $ip.PrefixLength
                $o.mascara   = ConvertTo-MascaraIpv4 ([int] $ip.PrefixLength)
                $o.conectado = $true
            }
        } catch { }
        try {
            $o.gateway = [string] ((Get-NetRoute -InterfaceIndex $lan.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Sort-Object RouteMetric | Select-Object -First 1).NextHop)
        } catch { }
        try {
            $o.dns = @((Get-DnsClientServerAddress -InterfaceIndex $lan.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        } catch { }
    }
    $o
}

# --------------------------------------------------------------- placa Wi-Fi
function Invoke-Netsh {
    param([string[]] $Argumentos, [int] $TimeoutS = 15)
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (-not (Test-Path $netsh)) { return '' }
    [string] (Invoke-ProcessoComSaida -Caminho $netsh -Argumentos $Argumentos -TimeoutS $TimeoutS)
}

# Checagem rapida (so Get-NetAdapter, sem netsh) - a GUI usa ao entrar no passo 3.
function Test-TemPlacaWireless {
    try {
        [bool] (Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.InterfaceType -eq 71 })
    } catch { $false }
}

function Get-AdaptadorWireless {
    $o = [pscustomobject]@{
        presente = $false; nome = ''; status = ''; conectado = $false
        ssid = ''; sinal_pct = $null; redes_disponiveis = @()
    }

    $wa = $null
    try {
        $wa = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceType -eq 71 } | Select-Object -First 1   # 71 = ieee80211
    } catch { }
    if (-not $wa) { return $o }

    $o.presente = $true
    $o.nome     = [string] $wa.Name
    $o.status   = [string] $wa.Status

    $txt = Invoke-Netsh -Argumentos @('wlan', 'show', 'interfaces')
    foreach ($ln in ($txt -split "`r?`n")) {
        if     ($ln -match '^\s*SSID\s*:\s*(.+?)\s*$')            { $o.ssid = $Matches[1] }
        elseif ($ln -match '^\s*(Estado|State)\s*:\s*(.+?)\s*$')  { $o.status = $Matches[2] }
        elseif ($ln -match '^\s*(Sinal|Signal)\s*:\s*(\d+)\s*%')  { $o.sinal_pct = [int] $Matches[2] }
    }
    $o.conectado = ($o.ssid -ne '') -and ($o.status -match 'conect|connected')

    $txt2 = Invoke-Netsh -Argumentos @('wlan', 'show', 'networks')
    $redes = foreach ($ln in ($txt2 -split "`r?`n")) {
        if ($ln -match '^\s*SSID\s+\d+\s*:\s*(.+?)\s*$') { $Matches[1] }
    }
    $o.redes_disponiveis = @($redes | Where-Object { $_ } | Select-Object -Unique)
    $o
}

# Conecta a uma rede Wi-Fi WPA2-PSK criando um perfil temporario e chamando
# netsh wlan connect. Roda num runspace (nao na thread de UI).
function Connect-RedeWireless {
    param(
        [Parameter(Mandatory)] [string] $Ssid,
        [Parameter(Mandatory)] [string] $Senha,
        [int] $TimeoutS = 25
    )
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$(& $esc $Ssid)</name>
  <SSIDConfig><SSID><name>$(& $esc $Ssid)</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$(& $esc $Senha)</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dicon-wifi-{0}.xml' -f ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText($tmp, $xml, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-Netsh -Argumentos @('wlan', 'add', 'profile', ('filename="{0}"' -f $tmp), 'user=current') | Out-Null
        Invoke-Netsh -Argumentos @('wlan', 'connect', ('name="{0}"' -f $Ssid), ('ssid="{0}"' -f $Ssid)) | Out-Null

        $fim = (Get-Date).AddSeconds($TimeoutS)
        do {
            Start-Sleep -Milliseconds 1200
            $wf = Get-AdaptadorWireless
            if ($wf.conectado -and $wf.ssid -eq $Ssid) {
                return [pscustomobject]@{
                    ok = $true; ssid = $Ssid; sinal_pct = $wf.sinal_pct
                    mensagem = ('Conectado a "{0}" ({1}%).' -f $Ssid, $wf.sinal_pct)
                }
            }
        } while ((Get-Date) -lt $fim)

        [pscustomobject]@{
            ok = $false; ssid = $Ssid; sinal_pct = $null
            mensagem = ('Nao conectou a "{0}" em {1}s. Confira a senha e o alcance.' -f $Ssid, $TimeoutS)
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------- internet local: Ookla Speedtest
function ConvertTo-Mbps { param($BandwidthBytesSeg)
    if ($null -eq $BandwidthBytesSeg) { return $null }
    [math]::Round(([double] $BandwidthBytesSeg) * 8 / 1e6, 2)
}

# Roda o speedtest.exe (Ookla CLI) em --format=jsonl, com velocimetro ao vivo.
# Devolve o objeto achatado usado no relatorio / JSON.
function Test-InternetLocal {
    $cfg = Get-ConfigRedeLocal
    $r = [ordered]@{
        speedtest_ok    = $false
        speedtest_erro  = ''
        isp             = ''
        ip_externo      = ''
        servidor_nome   = ''
        servidor_local  = ''
        servidor_id     = $null
        servidor_host   = ''
        ping_ms         = $null
        jitter_ms       = $null
        perda_pct       = $null
        download_mbps   = $null
        upload_mbps     = $null
        download_lat_ms = $null
        upload_lat_ms   = $null
        resultado_url   = ''
        resultado_id    = ''
        quando          = (Get-Date).ToString('o')
    }

    $exe = Get-CaminhoSpeedtest
    if (-not $exe) {
        $r.speedtest_erro = 'speedtest.exe (Ookla CLI) nao esta em tools\. Copie o binario para a pasta e rode de novo.'
        Write-Log $r.speedtest_erro -Nivel Erro
        return [pscustomobject] $r
    }

    $argv = '--format=jsonl --progress=yes --accept-license --accept-gdpr'
    if ($cfg.speedtest_server_id) { $argv += ' --server-id={0}' -f $cfg.speedtest_server_id }
    if ($cfg.speedtest_extra_args) { $argv += ' ' + $cfg.speedtest_extra_args }
    Write-Log ("Speedtest (Ookla): {0} {1}" -f $exe, $argv) -Nivel Destaque

    $saida = Invoke-SpeedtestStreaming -Caminho $exe -Argumentos $argv -TimeoutS 120
    $res = @($saida.Eventos | Where-Object { $_.type -eq 'result' }) | Select-Object -Last 1
    $err = @($saida.Eventos | Where-Object { $_.type -eq 'error' }) | Select-Object -Last 1

    if (-not $res) {
        $r.speedtest_erro = if ($err -and $err.message) { [string] $err.message }
                            elseif ($saida.Erro) { ($saida.Erro -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) }
                            else { 'o speedtest nao concluiu (sem internet no local?).' }
        Write-Log ("Speedtest falhou: {0}" -f $r.speedtest_erro) -Nivel Erro
        return [pscustomobject] $r
    }

    $r.speedtest_ok    = $true
    $r.isp             = [string] $res.isp
    if ($res.PSObject.Properties['interface'] -and $res.interface) {
        $r.ip_externo = [string] $res.interface.externalIp
    }
    if ($res.PSObject.Properties['server'] -and $res.server) {
        $r.servidor_nome  = [string] $res.server.name
        $r.servidor_local = ('{0}{1}' -f [string] $res.server.location, $(if ($res.server.country) { ', ' + $res.server.country } else { '' }))
        $r.servidor_id    = $res.server.id
        $r.servidor_host  = [string] $res.server.host
    }
    if ($res.ping) {
        $r.ping_ms   = [math]::Round([double] $res.ping.latency, 1)
        $r.jitter_ms = [math]::Round([double] $res.ping.jitter, 1)
    }
    if ($res.PSObject.Properties['packetLoss'] -and $null -ne $res.packetLoss) {
        $r.perda_pct = [math]::Round([double] $res.packetLoss, 1)
    }
    if ($res.download) {
        $r.download_mbps = ConvertTo-Mbps $res.download.bandwidth
        if ($res.download.PSObject.Properties['latency'] -and $res.download.latency) {
            $r.download_lat_ms = [math]::Round([double] $res.download.latency.iqm, 1)
        }
    }
    if ($res.upload) {
        $r.upload_mbps = ConvertTo-Mbps $res.upload.bandwidth
        if ($res.upload.PSObject.Properties['latency'] -and $res.upload.latency) {
            $r.upload_lat_ms = [math]::Round([double] $res.upload.latency.iqm, 1)
        }
    }
    if ($res.PSObject.Properties['result'] -and $res.result) {
        $r.resultado_url = [string] $res.result.url
        $r.resultado_id  = [string] $res.result.id
    }
    Write-Log ("Speedtest OK: down {0} Mbps / up {1} Mbps / ping {2} ms ({3})" -f $r.download_mbps, $r.upload_mbps, $r.ping_ms, $r.isp) -Nivel Ok
    [pscustomobject] $r
}

# --------------------------------------------------------------- orquestracao
#   -SemInternet: so inventaria as placas (LAN + Wi-Fi), sem ping/DNS/download.
#                 A GUI usa nesse modo ao ENTRAR no passo 3 (probe rapido).
function Invoke-FaseLocal {
    param([switch] $SemInternet)

    if ($Global:ModoTeste -and $Global:FaseLocalSimulada) {
        $s = $Global:FaseLocalSimulada
        if ($SemInternet) {
            return [pscustomobject]@{ Host = $s.Host; Lan = $s.Lan; Wireless = $s.Wireless; Internet = $null; Quando = $s.Quando }
        }
        return $s
    }

    Write-Log 'Fase 1 - rede local do local (SEM a VPN do TRE)' -Nivel Destaque

    $lan = Get-AdaptadorLan
    if ($lan.conectado) {
        Write-Log ("Placa LAN '{0}': conectada - IP {1} / gateway {2}" -f $lan.nome, $lan.ipv4, $lan.gateway) -Nivel Ok
    } elseif ($lan.presente) {
        Write-Log ("Placa LAN '{0}': sem IP (cabo desconectado?)." -f $lan.nome) -Nivel Aviso
    } else {
        Write-Log 'Nenhuma placa de rede cabeada encontrada neste computador.' -Nivel Aviso
    }
    if ($lan.descricao -match 'NDIS|Sharing|Tethering|Android|iPhone|\bPhone\b|Mobile Broadband') {
        Write-Log 'A placa de rede ativa parece ser roteamento de celular - marque a operadora no assistente.' -Nivel Info
    }

    $wf = Get-AdaptadorWireless
    if ($wf.conectado) {
        Write-Log ("Wi-Fi: conectado a '{0}' ({1}%)." -f $wf.ssid, $wf.sinal_pct) -Nivel Info
    } elseif ($wf.presente) {
        Write-Log ("Wi-Fi: placa presente, nao conectada ({0} rede(s) por perto)." -f (@($wf.redes_disponiveis).Count)) -Nivel Info
    } else {
        Write-Log 'Wi-Fi: sem placa wireless neste computador.' -Nivel Info
    }

    $net = if ($SemInternet) { $null } else { Test-InternetLocal }

    [pscustomobject]@{
        Host     = [string] $env:COMPUTERNAME
        Lan      = $lan
        Wireless = $wf
        Internet = $net
        Quando   = (Get-Date).ToString('o')
    }
}
