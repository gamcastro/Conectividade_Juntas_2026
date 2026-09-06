#Requires -Version 5.1
<#
.SYNOPSIS
    Gera um refresh token de SERVICO com escopo de Sheets + Drive, para a console
    DICON Web poder subir fotos do GEL (e, depois, arquivar PDFs) no Shared Drive
    da coordenacao.

    Faz um consentimento OAuth proprio (loopback 127.0.0.1), separado do
    "Conectar" da tela de Administracao -- assim NAO mexe nos escopos que os
    tecnicos de campo usam (config/ambiente.exemplo.json fica intacto). O token
    do DICON de campo continua so' com 'spreadsheets'.

    Ao final imprime a linha para colar UMA VEZ no editor do Apps Script de
    homologacao (Executar > setupServiceAuth):

        setupServiceAuth('<client_id>', '<client_secret>', '<refresh_token>')

.DESCRIPTION
    Escopos pedidos:
      https://www.googleapis.com/auth/spreadsheets    (gravar Resultados/abas)
      https://www.googleapis.com/auth/drive.file        (criar/gerir SO' os
                                                         arquivos que a console
                                                         criar -- nao le o resto
                                                         do Drive do George)

    Rode com a conta george.castro@tre-ma.jus.br (a dona do token de servico).
    Nada e' salvo em disco -- o refresh token so' aparece no console.
#>
[CmdletBinding()]
param(
    # Por padrao pede o escopo minimo (drive.file). Use -DriveTotal se precisar
    # que a console enxergue arquivos/pastas criados por fora dela.
    [switch] $DriveTotal
)

$ErrorActionPreference = 'Stop'
$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null
Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

$g = Get-ConfigOAuth
if (-not $g -or -not $g.client_id) {
    Write-Host 'OAuth nao configurado (config/ambiente.json > google_oauth).' -ForegroundColor Red
    exit 1
}

$escopoDrive = if ($DriveTotal) { 'https://www.googleapis.com/auth/drive' }
               else             { 'https://www.googleapis.com/auth/drive.file' }
$scopes = @(
    'openid'
    'https://www.googleapis.com/auth/userinfo.email'
    'https://www.googleapis.com/auth/spreadsheets'
    $escopoDrive
) -join ' '

# --- PKCE
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
        'client_id=' + [Uri]::EscapeDataString($g.client_id)
        'redirect_uri=' + [Uri]::EscapeDataString($redirect)
        'response_type=code'
        'scope=' + [Uri]::EscapeDataString($scopes)
        'code_challenge=' + $challenge
        'code_challenge_method=S256'
        'access_type=offline'
        'prompt=consent'
    ) -join '&'
    $url = $g.auth_uri + '?' + $qs

    Write-Host ''
    Write-Host 'Abrindo o navegador. Entre com george.castro@tre-ma.jus.br e clique em Permitir.' -ForegroundColor Cyan
    Write-Host "Se nao abrir, cole a URL no navegador:`n$url" -ForegroundColor DarkGray
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
    $html = '<!doctype html><meta charset="utf-8"><body style="font-family:Segoe UI,sans-serif;padding:2.5em;color:#0f1319"><h2>DICON</h2><p>Token de servico gerado. Volte ao PowerShell.</p></body>'
    $resp = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($html))`r`nConnection: close`r`n`r`n$html"
    $sw = [IO.StreamWriter]::new($ns); $sw.Write($resp); $sw.Flush(); $cli.Close()

    if ($erroOauth) { throw "consentimento recusado ($erroOauth)." }
    if (-not $codigo) { throw 'nao recebi o codigo de autorizacao do Google.' }

    $tk = Invoke-RestMethod -Method Post -Uri $g.token_uri -TimeoutSec 30 -Body @{
        client_id     = $g.client_id
        client_secret = $g.client_secret
        code          = $codigo
        code_verifier = $verifier
        grant_type    = 'authorization_code'
        redirect_uri  = $redirect
    }
    if (-not $tk.refresh_token) {
        throw 'o Google nao devolveu refresh_token (revogue o acesso do app em myaccount.google.com/permissions e tente de novo).'
    }

    $email = ''
    try { if ($tk.id_token) { $email = Get-JwtEmail $tk.id_token } } catch { }

    Write-Host ''
    Write-Host "Conta            : $email" -ForegroundColor Cyan
    Write-Host "Escopo do Drive  : $escopoDrive" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Cole no editor do Apps Script de HOMOLOGACAO (Executar > setupServiceAuth):' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  setupServiceAuth(' -NoNewline
    Write-Host "'$($g.client_id)', " -NoNewline -ForegroundColor Green
    Write-Host "'$($g.client_secret)', " -NoNewline -ForegroundColor Green
    Write-Host "'$($tk.refresh_token)'" -NoNewline -ForegroundColor Green
    Write-Host ')'
    Write-Host ''
    Write-Host 'Esse token da acesso de leitura/escrita as planilhas Google E aos arquivos' -ForegroundColor Yellow
    Write-Host 'criados pela console no Drive -- nao cole em nenhum outro lugar.' -ForegroundColor Yellow
} finally {
    try { $listener.Stop() } catch { }
}
