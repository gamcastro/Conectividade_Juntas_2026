#Requires -Version 5.1
<#
  DICON Web -- gera o refresh token de SERVICO (Sheets + Drive) para a console
  poder subir fotos do GEL no Drive.

  VERSAO AUTONOMA: nao precisa do repositorio nem do modulo do DICON. Roda em
  qualquer Windows com PowerShell (ex.: notebook de casa). O client_id /
  client_secret abaixo sao os mesmos do config/ambiente.exemplo.json do repo
  (client OAuth "app de computador" -- o "secret" dele nao e' confidencial).

  Como usar:
    1. Salve este arquivo (ou cole todo o conteudo no PowerShell).
    2. Rode:  powershell -ExecutionPolicy Bypass -File .\Conectar-DriveServico-Standalone.ps1
    3. No navegador que abrir: entre com george.castro@tre-ma.jus.br -> Permitir.
    4. Volte ao PowerShell: ele imprime o refresh token (comeca com "1//").
    5. Editor do Apps Script de HOMOLOGACAO -> engrenagem "Configuracoes do
       projeto" -> "Propriedades do script" -> edite OAUTH_REFRESH_TOKEN e cole
       so' esse valor -> Salvar. (OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET ja
       existem do setup anterior.)

  Nada e' salvo em disco -- o token so' aparece no console.
#>
[CmdletBinding()]
param([switch] $DriveTotal)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$CLIENT_ID     = '421295429657-ifb5evif7qk41lrgebk9vmmscaqk0j8s.apps.googleusercontent.com'
$CLIENT_SECRET = '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'
$AUTH_URI      = 'https://accounts.google.com/o/oauth2/v2/auth'
$TOKEN_URI     = 'https://oauth2.googleapis.com/token'

$escopoDrive = if ($DriveTotal) { 'https://www.googleapis.com/auth/drive' }
               else             { 'https://www.googleapis.com/auth/drive.file' }
$scopes = @(
    'openid'
    'https://www.googleapis.com/auth/userinfo.email'
    'https://www.googleapis.com/auth/spreadsheets'
    $escopoDrive
) -join ' '

function ConvertTo-Base64Url([byte[]] $b) {
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function Get-JwtEmail([string] $jwt) {
    try {
        $p = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        ((([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))) | ConvertFrom-Json).email)
    } catch { '' }
}

# PKCE
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$vb = [byte[]]::new(48); $rng.GetBytes($vb)
$verifier  = ConvertTo-Base64Url $vb
$challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    $porta    = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    $redirect = "http://127.0.0.1:$porta"
    $qs = @(
        'client_id=' + [Uri]::EscapeDataString($CLIENT_ID)
        'redirect_uri=' + [Uri]::EscapeDataString($redirect)
        'response_type=code'
        'scope=' + [Uri]::EscapeDataString($scopes)
        'code_challenge=' + $challenge
        'code_challenge_method=S256'
        'access_type=offline'
        'prompt=consent'
    ) -join '&'
    $url = $AUTH_URI + '?' + $qs

    Write-Host ''
    Write-Host 'Abrindo o navegador. Entre com george.castro@tre-ma.jus.br e clique em Permitir.' -ForegroundColor Cyan
    Write-Host "Se nao abrir, cole a URL no navegador:`n$url`n" -ForegroundColor DarkGray
    try { Start-Process $url } catch { Start-Process 'rundll32.exe' ("url.dll,FileProtocolHandler " + $url) }

    $ini = Get-Date
    while (-not $listener.Pending()) {
        if (((Get-Date) - $ini).TotalSeconds -gt 240) { throw 'tempo esgotado esperando o navegador.' }
        Start-Sleep -Milliseconds 250
    }
    $cli = $listener.AcceptTcpClient()
    $ns  = $cli.GetStream()
    $linha1 = ([IO.StreamReader]::new($ns)).ReadLine()
    $codigo = ''; $erroOauth = ''
    if ($linha1 -match 'code=([^ &]+)')  { $codigo   = [Uri]::UnescapeDataString($Matches[1]) }
    if ($linha1 -match 'error=([^ &]+)') { $erroOauth = $Matches[1] }
    $html = '<!doctype html><meta charset="utf-8"><body style="font-family:Segoe UI,sans-serif;padding:2.5em;color:#0f1319"><h2>DICON</h2><p>Token gerado. Volte ao PowerShell.</p></body>'
    $resp = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($html))`r`nConnection: close`r`n`r`n$html"
    $sw = [IO.StreamWriter]::new($ns); $sw.Write($resp); $sw.Flush(); $cli.Close()

    if ($erroOauth) { throw "consentimento recusado ($erroOauth)." }
    if (-not $codigo) { throw 'nao recebi o codigo de autorizacao do Google.' }

    $tk = Invoke-RestMethod -Method Post -Uri $TOKEN_URI -TimeoutSec 30 -Body @{
        client_id     = $CLIENT_ID
        client_secret = $CLIENT_SECRET
        code          = $codigo
        code_verifier = $verifier
        grant_type    = 'authorization_code'
        redirect_uri  = $redirect
    }
    if (-not $tk.refresh_token) {
        throw 'o Google nao devolveu refresh_token. Revogue "DICON" em myaccount.google.com/permissions e tente de novo.'
    }

    $email = ''
    if ($tk.id_token) { $email = Get-JwtEmail $tk.id_token }

    Write-Host ''
    Write-Host "Conta           : $email" -ForegroundColor Cyan
    Write-Host "Escopo do Drive : $escopoDrive" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor DarkGray
    Write-Host ' No editor do Apps Script de HOMOLOGACAO:' -ForegroundColor Yellow
    Write-Host '  Configuracoes do projeto > Propriedades do script >' -ForegroundColor Yellow
    Write-Host '  edite OAUTH_REFRESH_TOKEN e cole SO este valor:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  $($tk.refresh_token)" -ForegroundColor Green
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Se OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET nao existirem la:' -ForegroundColor DarkGray
    Write-Host "  OAUTH_CLIENT_ID     = $CLIENT_ID" -ForegroundColor DarkGray
    Write-Host "  OAUTH_CLIENT_SECRET = $CLIENT_SECRET" -ForegroundColor DarkGray
} finally {
    try { $listener.Stop() } catch { }
}
