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

# --------------------------------------------------------------- configuracao
function Get-ConfigRedeLocal {
    $def = [pscustomobject]@{
        ping_alvo          = '8.8.8.8'
        dns_nome           = 'www.tre-ma.jus.br'
        download_url       = 'https://speed.cloudflare.com/__down?bytes=8000000'
        download_timeout_s = 30
    }
    try {
        $c = Get-Config 'rede-local'
        foreach ($p in 'ping_alvo', 'dns_nome', 'download_url', 'download_timeout_s') {
            if ($c.PSObject.Properties[$p] -and "$($c.$p)" -ne '') { $def.$p = $c.$p }
        }
    } catch { }
    $def
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

# --------------------------------------------------------------- internet local
function Test-InternetLocal {
    $cfg = Get-ConfigRedeLocal
    $res = [ordered]@{
        ping_alvo = [string] $cfg.ping_alvo
        ping_ok = $false; ping_latencia_ms = $null; ping_perda_pct = $null
        ping_min_ms = $null; ping_max_ms = $null; ping_saida = @()
        dns_nome = [string] $cfg.dns_nome
        dns_ok = $false; dns_ms = $null; dns_ips = @()
        download_url = [string] $cfg.download_url
        download_ok = $false; download_mbps = $null; download_bytes = $null; download_seg = $null
    }
    $nPing = 4

    # ping publico - saida linha a linha, igual a do Windows (ping.exe)
    try {
        $pexe = Join-Path $env:SystemRoot 'System32\PING.EXE'
        if (-not (Test-Path $pexe)) { $pexe = 'ping' }
        $oem = try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { $null }
        Write-Log ("Internet local: ping {0} -n {1}..." -f $cfg.ping_alvo, $nPing) -Nivel Info
        $out = Invoke-ProcessoComSaida -Caminho $pexe -Argumentos @('-n', "$nPing", $cfg.ping_alvo) -TimeoutS 25 -Encoding $oem
        $linhas = @(($out -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
        $res.ping_saida = $linhas
        foreach ($ln in $linhas) { Write-Log ("  $ln") -Nivel Neutro }

        $tempos = @()
        foreach ($ln in $linhas) {
            if ($ln -match '(?:tempo|time)[=<]\s*(\d+)\s*ms') { $tempos += [int] $Matches[1] }
        }
        if ($tempos.Count -gt 0) {
            $res.ping_ok          = $true
            $res.ping_latencia_ms = [math]::Round((($tempos | Measure-Object -Average).Average), 1)
            $res.ping_min_ms      = ($tempos | Measure-Object -Minimum).Minimum
            $res.ping_max_ms      = ($tempos | Measure-Object -Maximum).Maximum
            $res.ping_perda_pct   = [math]::Round(($nPing - $tempos.Count) / $nPing * 100)
        } else {
            Write-Log 'Internet local: ping publico falhou (sem internet no local?).' -Nivel Aviso
        }
    } catch { Write-Log "Internet local: ping falhou ($_)." -Nivel Aviso }

    # resolucao DNS
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ips = @()
        try {
            $ips = @((Resolve-DnsName -Name $cfg.dns_nome -Type A -DnsOnly -ErrorAction Stop |
                        Where-Object { $_.IPAddress }).IPAddress)
        } catch {
            $ips = @([System.Net.Dns]::GetHostAddresses($cfg.dns_nome) | ForEach-Object { $_.IPAddressToString })
        }
        $sw.Stop()
        if ($ips.Count) {
            $res.dns_ok  = $true
            $res.dns_ms  = [math]::Round($sw.Elapsed.TotalMilliseconds)
            $res.dns_ips = $ips
            Write-Log ("Internet local: DNS {0} -> {1} ({2} ms)" -f $cfg.dns_nome, ($ips -join ', '), $res.dns_ms) -Nivel Info
        }
    } catch { Write-Log 'Internet local: resolucao DNS falhou.' -Nivel Aviso }

    # download de um arquivo pequeno (mostra alvo + tamanho)
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $to = [int] $cfg.download_timeout_s; if ($to -le 0) { $to = 30 }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dicon-dl-{0}.bin' -f ([guid]::NewGuid().ToString('N')))
        Write-Log ("Internet local: baixando de {0}..." -f $cfg.download_url) -Nivel Info
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { Invoke-WebRequest -Uri $cfg.download_url -OutFile $tmp -UseBasicParsing -TimeoutSec $to -ErrorAction Stop }
        finally { $ProgressPreference = $old }
        $sw.Stop()
        $bytes = if (Test-Path $tmp) { (Get-Item $tmp).Length } else { 0 }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($bytes -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0) {
            $res.download_ok    = $true
            $res.download_bytes = $bytes
            $res.download_seg   = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            $res.download_mbps  = [math]::Round(($bytes * 8) / $sw.Elapsed.TotalSeconds / 1e6, 1)
            Write-Log ("Internet local: {0} KB em {1}s (~{2} Mbps)" -f [math]::Round($bytes / 1KB), $res.download_seg, $res.download_mbps) -Nivel Info
        }
    } catch { Write-Log 'Internet local: mini download falhou.' -Nivel Aviso }

    [pscustomobject] $res
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
