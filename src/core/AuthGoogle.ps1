# Autenticacao Google (OAuth 2.0) para falar com o Web App do Apps Script quando
# ele e publicado com acesso "Qualquer pessoa do dominio" (DOMAIN) em vez de
# anonimo. Config em config/ambiente.json > google_oauth. O refresh token e
# gravado com DPAPI (por usuario Windows) em %LOCALAPPDATA%\DICON\.
#
# Consentimento (1x por maquina/usuario): loopback 127.0.0.1 (sem admin) e, de
# fallback, device-code ("acesse google.com/device e digite <codigo>").
#
# enabled=false (padrao do pacote) -> Get-CabecalhoAuthWebApp devolve @{} e nada
# no fluxo atual muda.

$Global:GoogleToken = $null   # @{ access; expira_em (DateTime); email }

$script:GOAuthDefaults = @{
    auth_uri   = 'https://accounts.google.com/o/oauth2/v2/auth'
    token_uri  = 'https://oauth2.googleapis.com/token'
    device_uri = 'https://oauth2.googleapis.com/device/code'
    scopes     = 'openid https://www.googleapis.com/auth/userinfo.email'
}

# Bloco google_oauth normalizado com os defaults. Le config/ambiente.json e o
# .exemplo.json; o real vence campo a campo, o exemplo preenche o que faltar
# (assim so preencher o client_id no .exemplo.json ja basta numa maquina antiga
# que tem ambiente.json sem o bloco). $null se nao houver bloco em lugar nenhum.
function Get-ConfigOAuth {
    $ovr = Get-Variable -Name OAuthConfigOverride -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($ovr) { return $ovr }   # hook de teste
    $dir = Join-Path $Global:RaizApp 'config'
    $le = {
        param($nome)
        $p = Join-Path $dir $nome
        if (-not (Test-Path $p)) { return $null }
        try { (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).google_oauth } catch { $null }
    }
    $real = & $le 'ambiente.json'
    $ex   = & $le 'ambiente.exemplo.json'
    if (-not $real -and -not $ex) { return $null }
    $pick = {
        param($k, $default)
        foreach ($src in $real, $ex) {
            if ($src -and $src.PSObject.Properties[$k]) {
                $v = $src.$k
                if ($k -eq 'enabled') { return [bool] $v }
                if ("$v") { return [string] $v }
            }
        }
        return $default
    }
    $g = @{}
    foreach ($k in 'auth_uri', 'token_uri', 'device_uri', 'scopes') { $g[$k] = & $pick $k $script:GOAuthDefaults[$k] }
    $g['client_id']     = & $pick 'client_id' ''
    $g['client_secret'] = & $pick 'client_secret' ''
    $g['enabled']       = & $pick 'enabled' $false
    return $g
}

# OAuth ligado E com client_id preenchido?
function Test-OAuthAtivo {
    $g = Get-ConfigOAuth
    [bool] ($g -and $g.enabled -and $g.client_id)
}

function Get-CaminhoTokenGoogle {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    $dir = Join-Path $base 'DICON'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir 'google-refresh.dat'
}

# --- refresh token: DPAPI (CurrentUser) -------------------------------------
function Save-RefreshTokenGoogle {
    param([Parameter(Mandatory)] [string] $Token, [string] $Email = '')
    $plain = ([pscustomobject]@{ rt = $Token; email = $Email; em = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
    $sec = ConvertTo-SecureString $plain -AsPlainText -Force
    [IO.File]::WriteAllText((Get-CaminhoTokenGoogle), (ConvertFrom-SecureString $sec))
}
function Get-RefreshTokenGoogle {
    $arq = Get-CaminhoTokenGoogle
    if (-not (Test-Path $arq)) { return $null }
    try {
        $sec  = ConvertTo-SecureString ([IO.File]::ReadAllText($arq))
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        return ($plain | ConvertFrom-Json)
    } catch { return $null }
}
function Clear-RefreshTokenGoogle {
    $arq = Get-CaminhoTokenGoogle
    if (Test-Path $arq) { Remove-Item $arq -Force -ErrorAction SilentlyContinue }
    $Global:GoogleToken = $null
}

# --- device-code: info para a UI mostrar (arquivo, p/ atravessar o runspace) --
function Get-CaminhoDeviceInfo { Join-Path (Get-PastaDados) 'google-device.json' }
function Set-DeviceInfoGoogle {
    param($Info)
    try { [IO.File]::WriteAllText((Get-CaminhoDeviceInfo), ($Info | ConvertTo-Json -Compress)) } catch { }
}
function Get-DeviceInfoGoogle {
    $arq = Get-CaminhoDeviceInfo
    if (-not (Test-Path $arq)) { return $null }
    try { Get-Content $arq -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}
function Clear-DeviceInfoGoogle {
    $arq = Get-CaminhoDeviceInfo
    if (Test-Path $arq) { Remove-Item $arq -Force -ErrorAction SilentlyContinue }
}

# --- helpers -------------------------------------------------------------------
function ConvertTo-Base64Url {
    param([byte[]] $Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
# Le o campo "error" do corpo JSON de uma resposta HTTP que falhou (Invoke-* lanca
# em >=400 e nao expoe o corpo em "$_"). Devolve '' se nao achar.
function Get-OAuthErro {
    param($ErrRecord)
    try {
        $r = $ErrRecord.Exception.Response
        if ($r) {
            $sr = [IO.StreamReader]::new($r.GetResponseStream())
            $txt = $sr.ReadToEnd(); $sr.Close()
            if ($txt) { return [string] ($txt | ConvertFrom-Json).error }
        }
    } catch { }
    return ''
}

function Get-JwtEmail {
    param([string] $IdToken)
    try {
        $p = $IdToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        return [string] (([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).email)
    } catch { return '' }
}

# Resposta do token endpoint -> $Global:GoogleToken (+ arquivo do refresh token).
function Set-TokenGoogle {
    param($Resp)
    $email = if ($Resp.id_token) { Get-JwtEmail $Resp.id_token } else { '' }
    if (-not $email -and $Global:GoogleToken) { $email = [string] $Global:GoogleToken.email }
    $Global:GoogleToken = @{
        access    = [string] $Resp.access_token
        expira_em = (Get-Date).AddSeconds([int] $Resp.expires_in - 60)
        email     = $email
    }
    if ($Resp.refresh_token) { Save-RefreshTokenGoogle -Token ([string] $Resp.refresh_token) -Email $email }
    return $Global:GoogleToken
}

# Access token valido (usa o cache; senao faz refresh silencioso). Sem refresh
# token / refresh falhou -> lanca 'CONECTAR_GOOGLE'.
function Get-TokenGoogle {
    param([switch] $Forcar)
    if (-not $Forcar -and $Global:GoogleToken -and $Global:GoogleToken.access -and
        (Get-Date) -lt $Global:GoogleToken.expira_em) {
        return $Global:GoogleToken.access
    }
    $g = Get-ConfigOAuth
    if (-not $g -or -not $g.enabled) { return $null }
    $rt = Get-RefreshTokenGoogle
    if (-not $rt -or -not $rt.rt) { throw 'CONECTAR_GOOGLE' }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $g.token_uri -TimeoutSec 30 -Body @{
            client_id     = $g.client_id
            client_secret = $g.client_secret
            refresh_token = $rt.rt
            grant_type    = 'refresh_token'
        }
    } catch {
        Clear-RefreshTokenGoogle          # refresh token revogado/expirado
        throw 'CONECTAR_GOOGLE'
    }
    if (-not $Global:GoogleToken) { $Global:GoogleToken = @{ email = [string] $rt.email } }
    (Set-TokenGoogle $resp).access
}

# Header para as chamadas ao /exec. @{} quando OAuth desligado.
function Get-CabecalhoAuthWebApp {
    if (-not (Test-OAuthAtivo)) { return @{} }
    $t = Get-TokenGoogle          # pode lancar CONECTAR_GOOGLE
    if ($t) { return @{ Authorization = "Bearer $t" } }
    return @{}
}

function Get-EmailGoogleConectado {
    if ($Global:GoogleToken -and $Global:GoogleToken.email) { return [string] $Global:GoogleToken.email }
    $rt = Get-RefreshTokenGoogle
    if ($rt -and $rt.email) { return [string] $rt.email }
    if ($rt -and $rt.rt) { return '(conta conectada)' }
    return ''
}

function Disconnect-GoogleConta {
    Clear-RefreshTokenGoogle
    Clear-DeviceInfoGoogle
    Write-Log 'Conta Google desconectada deste computador.' -Nivel Info
}

# --- consentimento interativo (roda via Start-TarefaRede) ---------------------
# Tenta loopback; se o TcpListener nao subir, cai no device-code. Devolve o
# email; lanca em erro.
function Connect-GoogleConta {
    $g = Get-ConfigOAuth
    if (-not $g -or -not $g.client_id) { throw 'OAuth nao configurado (config/ambiente.json > google_oauth).' }
    Clear-DeviceInfoGoogle

    # PKCE
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $vb = [byte[]]::new(48); $rng.GetBytes($vb)
    $verifier  = ConvertTo-Base64Url $vb
    $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))

    $listener = $null
    if (-not (Get-Variable -Name OAuthTestForceDeviceCode -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) {
        try { $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start() }
        catch { if ($listener) { try { $listener.Stop() } catch { } }; $listener = $null }
    }

    if ($listener) {
        try {
            $porta = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
            $redirect = "http://127.0.0.1:$porta"
            $qs = @(
                'client_id=' + [Uri]::EscapeDataString($g.client_id)
                'redirect_uri=' + [Uri]::EscapeDataString($redirect)
                'response_type=code'
                'scope=' + [Uri]::EscapeDataString($g.scopes)
                'code_challenge=' + $challenge
                'code_challenge_method=S256'
                'access_type=offline'
                'prompt=consent'
            ) -join '&'
            $url = $g.auth_uri + '?' + $qs
            if (Get-Variable -Name OAuthTestNoBrowser -Scope Global -ValueOnly -ErrorAction SilentlyContinue) {
                Set-DeviceInfoGoogle @{ redirect = $redirect; auth_url = $url }   # teste: sem navegador
            } else {
                try { Start-Process $url } catch { Start-Process 'rundll32.exe' ("url.dll,FileProtocolHandler " + $url) }
            }
            Write-Log 'Abrindo o navegador para conectar a conta Google (escolha a conta e clique em Permitir)...' -Nivel Info

            $ini = Get-Date
            while (-not $listener.Pending()) {
                if (((Get-Date) - $ini).TotalSeconds -gt 180) { throw 'tempo esgotado esperando o navegador (login Google).' }
                Start-Sleep -Milliseconds 250
            }
            $cli = $listener.AcceptTcpClient()
            $ns  = $cli.GetStream()
            $linha1 = ([IO.StreamReader]::new($ns)).ReadLine()      # "GET /?code=... HTTP/1.1"
            $codigo = ''; $erroOauth = ''
            if ($linha1 -match 'code=([^ &]+)')  { $codigo   = [Uri]::UnescapeDataString($Matches[1]) }
            if ($linha1 -match 'error=([^ &]+)') { $erroOauth = $Matches[1] }
            $html = '<!doctype html><meta charset="utf-8"><body style="font-family:Segoe UI,sans-serif;padding:2.5em;color:#0f1319"><h2>DICON</h2><p>Conta conectada. Pode fechar esta aba e voltar ao DICON.</p></body>'
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
            $st = Set-TokenGoogle $tk
            Write-Log ("Conta Google conectada: {0}" -f $st.email) -Nivel Ok
            return $st.email
        } finally {
            try { $listener.Stop() } catch { }
            Clear-DeviceInfoGoogle
        }
    }

    # --- fallback: device-code ---
    Write-Log 'Sem porta local disponivel - usando o codigo de dispositivo.' -Nivel Aviso
    $dc = Invoke-RestMethod -Method Post -Uri $g.device_uri -TimeoutSec 30 -Body @{ client_id = $g.client_id; scope = $g.scopes }
    $verUrl = & { if ($dc.verification_url) { $dc.verification_url } elseif ($dc.verification_uri) { $dc.verification_uri } else { 'https://www.google.com/device' } }
    Set-DeviceInfoGoogle @{ user_code = [string] $dc.user_code; verification_url = [string] $verUrl }
    Write-Log ("Acesse {0} e digite: {1}" -f $verUrl, $dc.user_code) -Nivel Destaque
    $intervalo = [int] (& { if ($dc.interval) { $dc.interval } else { 5 } })
    $fim = (Get-Date).AddSeconds([int] (& { if ($dc.expires_in) { $dc.expires_in } else { 900 } }))
    try {
        while ((Get-Date) -lt $fim) {
            Start-Sleep -Seconds $intervalo
            try {
                $tk = Invoke-RestMethod -Method Post -Uri $g.token_uri -TimeoutSec 30 -Body @{
                    client_id     = $g.client_id
                    client_secret = $g.client_secret
                    device_code   = [string] $dc.device_code
                    grant_type    = 'urn:ietf:params:oauth:grant-type:device_code'
                }
                $st = Set-TokenGoogle $tk
                Write-Log ("Conta Google conectada: {0}" -f $st.email) -Nivel Ok
                return $st.email
            } catch {
                $e = Get-OAuthErro $_
                if (-not $e) { $e = "$_" }
                if ($e -match 'authorization_pending|slow_down') { continue }
                if ($e -match 'access_denied') { throw 'consentimento recusado.' }
                if ($e -match 'expired_token') { throw 'o codigo de dispositivo expirou - tente de novo.' }
                throw $e
            }
        }
        throw 'o codigo de dispositivo expirou - tente de novo.'
    } finally {
        Clear-DeviceInfoGoogle
    }
}
