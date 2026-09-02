# Coleta o estado do notebook/rede no momento do teste. Vai junto no JSON de
# resultado para contextualizar a medicao.

# VPN da Justica Eleitoral conectada? (FortiClient SSL VPN e afins.)
$Global:VpnPadraoRegex = 'VPN|WireGuard|OpenVPN|TAP|PANGP|AnyConnect|Fortinet|FortiClient|FortiSSL|GlobalProtect|SSL VPN'

function Test-VpnAtiva {
    if ($Global:ModoTeste -and $null -ne $Global:VpnSimulada) { return [bool] $Global:VpnSimulada }
    try {
        return [bool] (Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match $Global:VpnPadraoRegex
        })
    } catch { return $false }
}

# Detalhes da placa da VPN da JE quando conectada (IP, interface, gateway, DNS)
# - usado no overlay de checagem para confirmar visualmente a conexao.
function Get-DetalheVpn {
    $o = [pscustomobject]@{ ativa = $false; nome = ''; descricao = ''; ipv4 = ''; gateway = ''; dns = @() }

    if ($Global:ModoTeste -and $null -ne $Global:VpnSimulada) {
        if ([bool] $Global:VpnSimulada) {
            $o.ativa = $true; $o.nome = 'FortiClient VPN (simulada)'; $o.descricao = 'Fortinet SSL VPN Virtual Ethernet Adapter'
            $o.ipv4 = '10.11.253.51'; $o.gateway = ''; $o.dns = @('10.11.1.1')
        }
        return $o
    }

    try {
        $ad = Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match $Global:VpnPadraoRegex
        } | Select-Object -First 1
        if (-not $ad) { return $o }
        $o.ativa = $true
        $o.nome = [string] $ad.Name
        $o.descricao = [string] $ad.InterfaceDescription
        try {
            $ip = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1
            if ($ip) { $o.ipv4 = [string] $ip.IPAddress }
        } catch { }
        try {
            $o.gateway = [string] ((Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Sort-Object RouteMetric | Select-Object -First 1).NextHop)
        } catch { }
        if ($o.gateway -eq '0.0.0.0') { $o.gateway = '' }
        try {
            $o.dns = @((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        } catch { }
    } catch { }
    return $o
}

# Caminho do executavel do FortiClient (para o botao "Abrir o FortiClient").
function Get-CaminhoFortiClient {
    $cands = @(
        (Join-Path $env:ProgramFiles        'Fortinet\FortiClient\FortiClient.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Fortinet\FortiClient\FortiClient.exe')
        (Join-Path $env:ProgramFiles        'Fortinet\FortiClient\FortiClientConsole.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Fortinet\FortiClient\FortiClientConsole.exe')
        (Join-Path $env:ProgramFiles        'Fortinet\FortiClient\FortiTray.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command 'FortiClient.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($k in 'HKLM:\SOFTWARE\Fortinet\FortiClient', 'HKLM:\SOFTWARE\WOW6432Node\Fortinet\FortiClient') {
        try {
            $d = (Get-ItemProperty -Path $k -ErrorAction Stop).InstallDir
            if ($d) { $p = Join-Path $d 'FortiClient.exe'; if (Test-Path $p) { return $p } }
        } catch { }
    }
    return $null
}

function Get-EstadoAmbiente {
    $vpn = $null
    try {
        $vpn = [bool] (Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and
            $_.InterfaceDescription -match 'VPN|WireGuard|OpenVPN|TAP|PANGP|AnyConnect|Fortinet|GlobalProtect'
        })
    } catch { $vpn = $null }

    $interfacePrincipal = $null
    try {
        $interfacePrincipal = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric |
            Select-Object -First 1 -ExpandProperty InterfaceAlias
    } catch { }

    [pscustomobject]@{
        host               = $env:COMPUTERNAME
        usuario            = $env:USERNAME
        so                 = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        vpn_ativa          = $vpn
        interface_principal = $interfacePrincipal
        coletado_em        = (Get-Date).ToString('o')
    }
}
