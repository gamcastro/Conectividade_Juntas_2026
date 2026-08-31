# Fase 1 do diagnostico: a rede LOCAL do local, ANTES de conectar a VPN do TRE.
#
#   - inventario da placa de rede cabeada (LAN): conectada? IP, mascara, gateway,
#     DNS, MAC, velocidade do enlace  -> o IP local vai no relatorio final
#   - placa wireless: existe? conectada a que SSID? redes por perto
#   - internet local: ping publico + resolucao DNS + mini download (nocao de banda)
#   - conexao a uma rede Wi-Fi por dentro da ferramenta (netsh wlan)
#
# Depois desta fase o tecnico conecta a VPN do TRE e roda a bateria "com VPN"
# (Invoke-DiagnosticoCompleto).

# --- feeds ao vivo do teste de internet (ping / tracert / download) ----------
# ObservableCollections ligadas por binding as 3 colunas do card. Alimentadas
# linha a linha por Write-LinhaRede (marshalla para o Dispatcher, como Write-Log).
foreach ($__n in 'RedePing', 'RedeTracert', 'RedeDownload') {
    if (-not (Get-Variable -Name $__n -Scope Global -ErrorAction SilentlyContinue)) {
        Set-Variable -Name $__n -Scope Global `
            -Value ([System.Collections.ObjectModel.ObservableCollection[object]]::new())
    }
}

function Write-LinhaRede {
    param(
        [ValidateSet('ping', 'tracert', 'download')] [string] $Alvo,
        [string] $Texto = ''
    )
    # via hashtable: 'switch'/'$()' desenrolam colecao vazia para $null.
    $col = @{ ping = $Global:RedePing; tracert = $Global:RedeTracert; download = $Global:RedeDownload }[$Alvo]
    if ($null -eq $col) { return }

    $janela = Get-Variable -Name JanelaPrincipal -Scope Global -ErrorAction SilentlyContinue
    $dispatcher = if ($janela) { $janela.Value.Dispatcher } else { $null }
    $aplicar = { $col.Add($Texto) }
    if ($dispatcher -and -not $dispatcher.CheckAccess()) {
        $dispatcher.Invoke([action] $aplicar)
    } else {
        & $aplicar
    }
}

# --------------------------------------------------------------- configuracao
function Get-ConfigRedeLocal {
    $def = [pscustomobject]@{
        ping_alvo          = '8.8.8.8'
        dns_nome           = 'www.tre-ma.jus.br'
        download_url       = 'https://speed.cloudflare.com/__down?bytes=8000000'
        download_timeout_s = 30
        tracert_host       = ''
        tracert_saltos     = 12
    }
    try {
        $c = Get-Config 'rede-local'
        foreach ($p in 'ping_alvo', 'dns_nome', 'download_url', 'download_timeout_s', 'tracert_host', 'tracert_saltos') {
            if ($c.PSObject.Properties[$p] -and "$($c.$p)" -ne '') { $def.$p = $c.$p }
        }
    } catch { }
    if (-not $def.tracert_host) { $def.tracert_host = $def.dns_nome }
    if ([int] $def.tracert_saltos -le 0) { $def.tracert_saltos = 12 }
    $def
}

# Encoding OEM do console (ping.exe / tracert.exe usam), p/ acentos corretos.
function Get-EncodingOem {
    try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { $null }
}

# Roda um .exe de console lendo o stdout LINHA A LINHA e mandando cada uma
# para a coluna $Alvo (feed ao vivo). Devolve todas as linhas.
function Invoke-ProcessoStreaming {
    param(
        [string] $Caminho, [string] $Argumentos, [string] $Alvo, [int] $TimeoutS = 60
    )
    $linhas = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $Caminho)) {
        $cmd = Get-Command $Caminho -ErrorAction SilentlyContinue
        if ($cmd) { $Caminho = $cmd.Source } else { return $linhas }
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Caminho
    $psi.Arguments              = $Argumentos
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $oem = Get-EncodingOem
    if ($oem) { $psi.StandardOutputEncoding = $oem; $psi.StandardErrorEncoding = $oem }

    try {
        $p = [Diagnostics.Process]::Start($psi)
        while ($null -ne ($ln = $p.StandardOutput.ReadLine())) {
            $t = $ln.TrimEnd()
            if ($t -eq '') { continue }
            $linhas.Add($t)
            Write-LinhaRede -Alvo $Alvo -Texto $t
        }
        if (-not $p.WaitForExit($TimeoutS * 1000)) { try { $p.Kill() } catch { } }
    } catch {
        $linhas.Add("falhou: $_")
        Write-LinhaRede -Alvo $Alvo -Texto "falhou: $_"
    }
    $linhas
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

# --------------------------------------------------------------- PING (streaming)
function Test-PingLocal {
    param([string] $Alvo, [int] $Contagem = 4)
    $r = [pscustomobject]@{ ok = $false; media_ms = $null; min_ms = $null; max_ms = $null; perda_pct = $null; saida = @() }
    $pexe = Join-Path $env:SystemRoot 'System32\PING.EXE'
    Write-LinhaRede -Alvo 'ping' -Texto ("> ping -n {0} {1}" -f $Contagem, $Alvo)
    $linhas = Invoke-ProcessoStreaming -Caminho $pexe -Argumentos ("-n $Contagem $Alvo") -Alvo 'ping' -TimeoutS 25
    $r.saida = @($linhas)
    $tempos = @()
    foreach ($ln in $linhas) {
        if ($ln -match '(?:tempo|time)[=<]\s*(\d+)\s*ms') { $tempos += [int] $Matches[1] }
    }
    if ($tempos.Count) {
        $r.ok        = $true
        $r.media_ms  = [math]::Round((($tempos | Measure-Object -Average).Average), 1)
        $r.min_ms    = ($tempos | Measure-Object -Minimum).Minimum
        $r.max_ms    = ($tempos | Measure-Object -Maximum).Maximum
        $r.perda_pct = [math]::Round(($Contagem - $tempos.Count) / $Contagem * 100)
    }
    $r
}

# ---------------------------------------------------- DNS + TRACERT (streaming)
function Test-TracertLocal {
    param([string] $NomeDns, [string] $Destino, [int] $Saltos = 12)
    $r = [pscustomobject]@{ dns_ok = $false; dns_ms = $null; dns_ips = @(); tracert_ok = $false; tracert_saltos = 0; saida = @() }

    Write-LinhaRede -Alvo 'tracert' -Texto ("> resolvendo {0}" -f $NomeDns)
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ips = @()
        try { $ips = @((Resolve-DnsName -Name $NomeDns -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress) }
        catch { $ips = @([System.Net.Dns]::GetHostAddresses($NomeDns) | ForEach-Object { $_.IPAddressToString }) }
        $sw.Stop()
        if ($ips.Count) {
            $r.dns_ok = $true; $r.dns_ms = [math]::Round($sw.Elapsed.TotalMilliseconds); $r.dns_ips = $ips
            Write-LinhaRede -Alvo 'tracert' -Texto ("{0}  ->  {1}   ({2} ms)" -f $NomeDns, ($ips -join ', '), $r.dns_ms)
        } else {
            Write-LinhaRede -Alvo 'tracert' -Texto ("resolucao de {0} falhou" -f $NomeDns)
        }
    } catch { Write-LinhaRede -Alvo 'tracert' -Texto ("resolucao de {0} falhou" -f $NomeDns) }

    $texe = Join-Path $env:SystemRoot 'System32\TRACERT.EXE'
    Write-LinhaRede -Alvo 'tracert' -Texto ("> tracert -d -h {0} {1}" -f $Saltos, $Destino)
    $linhas = Invoke-ProcessoStreaming -Caminho $texe -Argumentos ("-d -h $Saltos -w 700 $Destino") -Alvo 'tracert' -TimeoutS 90
    $r.saida = @($linhas)
    foreach ($ln in $linhas) { if ($ln -match '^\s*(\d+)\s') { $r.tracert_saltos = [int] $Matches[1] } }
    $r.tracert_ok = ($r.tracert_saltos -gt 0)
    $r
}

# --------------------------------------------------- DOWNLOAD (streaming, %)
function Test-DownloadLocal {
    param([string] $Url, [int] $TimeoutS = 30)
    $r = [pscustomobject]@{ ok = $false; mbps = $null; bytes = $null; seg = $null; saida = @() }
    $linhas = New-Object System.Collections.Generic.List[string]
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    Write-LinhaRede -Alvo 'download' -Texto ("> GET {0}" -f $Url); $linhas.Add("> GET $Url")
    try {
        $req = [Net.HttpWebRequest] [Net.WebRequest]::Create($Url)
        $req.Timeout = $TimeoutS * 1000
        $req.ReadWriteTimeout = $TimeoutS * 1000
        $req.UserAgent = 'DICON'
        $resp = $req.GetResponse()
        $total = [int64] $resp.ContentLength
        $m = ("HTTP {0}   {1}" -f [int] $resp.StatusCode, $(if ($total -gt 0) { '{0} MB' -f [math]::Round($total / 1MB, 1) } else { 'tamanho ?' }))
        $linhas.Add($m); Write-LinhaRede -Alvo 'download' -Texto $m
        $st = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $lido = [int64] 0; $marca = [int64] 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
            $lido += $n
            if (($lido - $marca) -ge 1MB) {
                $marca = $lido
                $mbps = [math]::Round(($lido * 8) / $sw.Elapsed.TotalSeconds / 1e6, 1)
                $pct = if ($total -gt 0) { '{0,3}%  ' -f [math]::Round($lido * 100.0 / $total) } else { '' }
                $m = ("{0}{1} MB   {2} Mbps" -f $pct, [math]::Round($lido / 1MB, 1), $mbps)
                $linhas.Add($m); Write-LinhaRede -Alvo 'download' -Texto $m
            }
        }
        $sw.Stop(); $st.Close(); $resp.Close()
        $r.bytes = $lido; $r.seg = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        if ($lido -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0) {
            $r.ok = $true
            $r.mbps = [math]::Round(($lido * 8) / $sw.Elapsed.TotalSeconds / 1e6, 1)
            $m = ("concluido: {0} MB em {1}s   (~{2} Mbps)" -f [math]::Round($lido / 1MB, 2), $r.seg, $r.mbps)
            $linhas.Add($m); Write-LinhaRede -Alvo 'download' -Texto $m
        }
    } catch {
        $m = "falhou: $_"; $linhas.Add($m); Write-LinhaRede -Alvo 'download' -Texto $m
    }
    $r.saida = @($linhas)
    $r
}

# --------------------------------------------------------------- internet local
# Roda PING -> DNS/TRACERT -> DOWNLOAD, um de cada vez, transmitindo linha a linha.
function Test-InternetLocal {
    $cfg = Get-ConfigRedeLocal

    $pg = Test-PingLocal    -Alvo $cfg.ping_alvo -Contagem 4
    $tr = Test-TracertLocal -NomeDns $cfg.dns_nome -Destino $cfg.tracert_host -Saltos ([int] $cfg.tracert_saltos)
    $to = [int] $cfg.download_timeout_s; if ($to -le 0) { $to = 30 }
    $dl = Test-DownloadLocal -Url $cfg.download_url -TimeoutS $to

    [pscustomobject]@{
        ping_alvo        = [string] $cfg.ping_alvo
        ping_ok          = $pg.ok
        ping_latencia_ms = $pg.media_ms
        ping_min_ms      = $pg.min_ms
        ping_max_ms      = $pg.max_ms
        ping_perda_pct   = $pg.perda_pct
        ping_saida       = @($pg.saida)
        dns_nome         = [string] $cfg.dns_nome
        dns_ok           = $tr.dns_ok
        dns_ms           = $tr.dns_ms
        dns_ips          = @($tr.dns_ips)
        tracert_host     = [string] $cfg.tracert_host
        tracert_ok       = $tr.tracert_ok
        tracert_saltos   = $tr.tracert_saltos
        tracert_saida    = @($tr.saida)
        download_url     = [string] $cfg.download_url
        download_ok      = $dl.ok
        download_mbps    = $dl.mbps
        download_bytes   = $dl.bytes
        download_seg     = $dl.seg
        download_saida   = @($dl.saida)
    }
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
