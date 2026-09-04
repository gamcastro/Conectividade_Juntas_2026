# Chamadas ao Apps Script (apps-script/Codigo.gs) pela Execution API do Google
# (script.googleapis.com), em vez da URL /exec do Web App: um Web App com
# acesso restrito a dominio ('access': 'DOMAIN') so aceita sessao de
# navegador -- nunca um 'Authorization: Bearer' enviado por um programa
# (confirmado ao vivo, v0.6.72). A Execution API aceita token OAuth de
# verdade. Ver docs/oauth-google.md.

# Chama a funcao unica "executar" do Codigo.gs com {acao=$Acao} (+ campos de
# -Payload, se vier) como parametro. Devolve resp.response.result ja
# "desembrulhado" -- o mesmo shape que doGet/doPost devolviam antes (ex.:
# {atualizado_em; juntas:[...]}), entao quem chama nao precisa mudar.
function Invoke-FuncaoAppsScript {
    param(
        [Parameter(Mandatory)] [string] $Acao,
        $Payload = $null,
        [int] $TimeoutS = 45
    )

    # hook de teste: aponta para um host de mock em vez de script.googleapis.com
    # (dispensa config/juntas.json > deployment_id -- so pra testes)
    $ovr = Get-Variable -Name AppsScriptEndpointOverride -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $uri =
        if ($ovr) { [string] $ovr }
        else {
            # a Execution API usa o ID da implantacao "Executavel de API"
            # (Implantar > Gerenciar implantacoes no editor -- o mesmo
            # deploymentId da URL /exec), NAO o scriptId do projeto.
            $deploymentId = (Get-Config 'juntas').deployment_id
            if ([string]::IsNullOrWhiteSpace($deploymentId) -or $deploymentId -like '*COLOQUE_O_DEPLOYMENT_ID*') {
                throw "deployment_id do Apps Script nao configurado (config/juntas.json > deployment_id)."
            }
            "https://script.googleapis.com/v1/scripts/${deploymentId}:run"
        }

    $param0 =
        if ($Payload -is [hashtable]) { $h0 = @{} + $Payload; $h0['acao'] = $Acao; $h0 }
        elseif ($Payload) { $Payload | Add-Member -NotePropertyName acao -NotePropertyValue $Acao -Force -PassThru }
        else { @{ acao = $Acao } }

    $corpo = @{ function = 'executar'; parameters = @($param0); devMode = $false } | ConvertTo-Json -Depth 20 -Compress

    for ($tent = 1; $tent -le 2; $tent++) {
        $h = Get-CabecalhoAuthWebApp   # pode lancar CONECTAR_GOOGLE
        if (-not $h.Authorization) { throw 'CONECTAR_GOOGLE' }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $h -Body $corpo `
                                      -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutS
            break
        } catch {
            $status = $null
            try { $status = [int] $_.Exception.Response.StatusCode } catch { }
            if ($tent -eq 1 -and ($status -eq 401 -or $status -eq 403)) { Get-TokenGoogle -Forcar | Out-Null; continue }
            throw
        }
    }

    if ($resp.error) {
        $msg = if ($resp.error.details -and @($resp.error.details).Count -and $resp.error.details[0].errorMessage) {
            [string] $resp.error.details[0].errorMessage
        } else { [string] $resp.error.message }
        throw "Apps Script ($Acao): $msg"
    }
    return $resp.response.result
}
