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
