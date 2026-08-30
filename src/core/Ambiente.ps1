# Coleta o estado do notebook/rede no momento do teste. Vai junto no JSON de
# resultado para contextualizar a medicao.

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
