#Requires -Version 5.1
<#
.SYNOPSIS
    Teste do modulo de autenticacao Google (src/core/AuthGoogle.ps1) contra um
    HttpListener local que simula os endpoints OAuth do Google (token + device).
    Nao abre navegador (hook $Global:OAuthTestNoBrowser).
#>
[CmdletBinding()]
param([int] $Porta = 0)

$ErrorActionPreference = 'Stop'

# porta livre (evita conflito quando rodado em sequencia com outros testes)
if ($Porta -le 0) {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $Porta = ([System.Net.IPEndPoint] $probe.LocalEndpoint).Port; $probe.Stop()
}
$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null
Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

# --- scratch: isola o token DPAPI e o arquivo de device-info -----------------
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dicon-authg-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $scratch 'data') -Force | Out-Null
$laOrig = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $scratch
$Global:PastaDadosOverride = Join-Path $scratch 'data'
$Global:OAuthTestForceDeviceCode = $true   # sem TcpListener/navegador - fluxo device-code puro HTTP

$base = "http://localhost:$Porta"
$Global:OAuthConfigOverride = @{
    enabled = $true; client_id = 'cid.apps.googleusercontent.com'; client_secret = 'sec'
    auth_uri = "$base/auth"; token_uri = "$base/token"; device_uri = "$base/device"
    scopes = 'openid https://www.googleapis.com/auth/userinfo.email'
}

# JWT (nao assinado - so o payload importa p/ Get-JwtEmail)
function New-FakeJwt {
    param([string] $Email)
    $b64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+','-').Replace('/','_') }
    ('{0}.{1}.sig' -f (& $b64 '{"alg":"none"}'), (& $b64 ("{`"email`":`"$Email`"}")))
}
$jwt = New-FakeJwt 'tecnico@tre-ma.jus.br'

# --- listener num runspace: roteia por caminho, conta as chamadas -----------
$cntFile = Join-Path $scratch 'calls.txt'
[IO.File]::WriteAllText($cntFile, '0')
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("$base/")
$listener.Start()
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('listener', $listener)
$rs.SessionStateProxy.SetVariable('cntFile', $cntFile)
$rs.SessionStateProxy.SetVariable('jwt', $jwt)
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void] $ps.AddScript({
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $req = $ctx.Request
            $body = ''
            if ($req.HasEntityBody) { $sr = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding); $body = $sr.ReadToEnd(); $sr.Dispose() }
            $path = $req.Url.AbsolutePath
            $out = '{}'; $code = 200
            if ($path -eq '/token') {
                $n = 0
                for ($try = 0; $try -lt 20; $try++) { try { $n = [int] ([IO.File]::ReadAllText($cntFile).Trim()); break } catch { Start-Sleep -Milliseconds 25 } }
                $n++
                for ($try = 0; $try -lt 20; $try++) { try { [IO.File]::WriteAllText($cntFile, "$n"); break } catch { Start-Sleep -Milliseconds 25 } }
                if ($body -match 'grant_type=refresh_token') {
                    $out = "{`"access_token`":`"AT-refresh-$n`",`"expires_in`":3600,`"id_token`":`"$jwt`"}"
                } elseif ($body -match 'grant_type=authorization_code' -and $body -match 'code=FAKECODE') {
                    $out = "{`"access_token`":`"AT-code`",`"expires_in`":3600,`"refresh_token`":`"RT-code`",`"id_token`":`"$jwt`"}"
                } elseif ($body -match 'device_code') {
                    if ($n -lt 3) { $code = 400; $out = '{"error":"authorization_pending"}' }
                    else { $out = "{`"access_token`":`"AT-dev`",`"expires_in`":3600,`"refresh_token`":`"RT-dev`",`"id_token`":`"$jwt`"}" }
                } else { $code = 400; $out = '{"error":"invalid_grant"}' }
            } elseif ($path -eq '/device') {
                $out = '{"device_code":"DEVCODE","user_code":"ABCD-EFGH","verification_url":"http://x/device","interval":1,"expires_in":60}'
            } elseif ($path -eq '/recurso') {
                if ($req.Headers['Authorization'] -like 'Bearer *') { $out = '{"ok":true,"origem":"mock"}' }
                else { $ctx.Response.ContentType = 'text/html'; $out = '<html><body>Sign in - accounts.google.com</body></html>' }
            }
            $ctx.Response.StatusCode = $code
            if (-not $ctx.Response.ContentType) { $ctx.Response.ContentType = 'application/json' }
            $buf = [Text.Encoding]::UTF8.GetBytes($out)
            $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
        } catch { }
        finally { $ctx.Response.Close() }
    }
})
$handle = $ps.BeginInvoke()

function Get-Calls {
    for ($try = 0; $try -lt 20; $try++) { try { return [int] ([IO.File]::ReadAllText($cntFile).Trim()) } catch { Start-Sleep -Milliseconds 25 } }
    return -1
}

$falhas = 0
try {
    # [1] OAuth desligado -> header vazio
    $Global:OAuthConfigOverride.enabled = $false
    if (-not (Test-OAuthAtivo) -and (Get-CabecalhoAuthWebApp).Count -eq 0) { Write-Host "[1] OAuth off -> Test-OAuthAtivo false, header vazio" }
    else { Write-Host "    FALHA: OAuth off"; $falhas++ }
    $Global:OAuthConfigOverride.enabled = $true

    # [2] Connect-GoogleConta pelo fluxo device-code (puro HTTP, deterministico):
    #     /device -> user_code; /token (device grant) rebate 'authorization_pending'
    #     ate a 3a chamada, quando devolve o access+refresh.
    $emailConn = ''
    try { $emailConn = Connect-GoogleConta } catch { $emailConn = "ERRO: $_" }
    if ($emailConn -eq 'tecnico@tre-ma.jus.br') { Write-Host "[2] Connect-GoogleConta (device-code) -> $emailConn" }
    else { Write-Host "    FALHA: connect ($emailConn)"; $falhas++ }
    if ($null -eq (Get-DeviceInfoGoogle)) { Write-Host "[2] arquivo de device-info limpo ao concluir" }
    else { Write-Host "    FALHA: device-info nao foi limpo"; $falhas++ }

    # [3] refresh token gravado (DPAPI), com o e-mail
    $Global:GoogleToken = $null
    $rt = Get-RefreshTokenGoogle
    if ($rt -and $rt.rt -eq 'RT-dev' -and $rt.email -eq 'tecnico@tre-ma.jus.br') { Write-Host "[3] refresh token gravado (DPAPI) com o e-mail" }
    else { Write-Host "    FALHA: refresh token (rt=$($rt.rt) email=$($rt.email))"; $falhas++ }

    # [4] Get-TokenGoogle faz refresh e Get-CabecalhoAuthWebApp devolve Bearer
    $c0 = Get-Calls
    $h1 = Get-CabecalhoAuthWebApp
    if ($h1['Authorization'] -match '^Bearer AT-refresh-\d+$' -and (Get-Calls) -eq $c0 + 1) { Write-Host "[4] refresh silencioso -> $($h1['Authorization'])" }
    else { Write-Host "    FALHA: refresh (h=$($h1['Authorization']) calls=$c0->$(Get-Calls))"; $falhas++ }

    # [5] token em cache -> nao rebate no /token
    $c1 = Get-Calls
    $h2 = Get-CabecalhoAuthWebApp
    if ($h2['Authorization'] -eq $h1['Authorization'] -and (Get-Calls) -eq $c1) { Write-Host "[5] token em cache reaproveitado (sem chamada)" }
    else { Write-Host "    FALHA: cache (calls=$c1->$(Get-Calls))"; $falhas++ }

    # [6] expira o cache -> novo refresh
    $Global:GoogleToken.expira_em = (Get-Date).AddMinutes(-1)
    $c2 = Get-Calls
    $h3 = Get-CabecalhoAuthWebApp
    if ($h3['Authorization'] -ne $h1['Authorization'] -and (Get-Calls) -eq $c2 + 1) { Write-Host "[6] cache expirado -> refaz o refresh ($($h3['Authorization']))" }
    else { Write-Host "    FALHA: expiracao (h=$($h3['Authorization']) calls=$c2->$(Get-Calls))"; $falhas++ }

    # [7] endpoint /recurso: HTML sem Bearer, JSON com Bearer
    $semAuth = try { (Invoke-WebRequest -Uri "$base/recurso" -UseBasicParsing).Content } catch { "$_" }
    $comAuth = try { Invoke-RestMethod -Uri "$base/recurso" -Headers (Get-CabecalhoAuthWebApp) } catch { $null }
    if ($semAuth -match '(?i)<html|accounts\.google\.com' -and $comAuth.ok) { Write-Host "[7] mock: sem Bearer -> HTML de login; com Bearer -> JSON" }
    else { Write-Host "    FALHA: recurso auth (sem='$($semAuth.Substring(0,[Math]::Min(40,$semAuth.Length)))' com.ok=$($comAuth.ok))"; $falhas++ }

    # [8] Disconnect limpa
    Disconnect-GoogleConta
    if (-not (Get-RefreshTokenGoogle) -and (Get-EmailGoogleConectado) -eq '') { Write-Host "[8] Disconnect-GoogleConta apaga o token" }
    else { Write-Host "    FALHA: disconnect nao limpou"; $falhas++ }
}
finally {
    $listener.Stop(); $listener.Close()
    try { $ps.EndInvoke($handle) } catch { }
    $ps.Dispose(); $rs.Dispose()
    $env:LOCALAPPDATA = $laOrig
    $Global:PastaDadosOverride = $null
    $Global:OAuthConfigOverride = $null
    $Global:OAuthTestForceDeviceCode = $null
    $Global:GoogleToken = $null
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: OK"; exit 0 }
else { Write-Host "RESULTADO: $falhas FALHA(S)"; exit 1 }
