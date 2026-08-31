#Requires -Version 5.1
<#
.SYNOPSIS
    Teste de integracao HEADLESS: login -> home -> guia de bordo -> diagnostico,
    com fixtures locais, sem exibir janela. Valida navegacao + fluxo assincrono.
#>
[CmdletBinding()]
param(
    [int] $TimeoutS = 120
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    & $exe -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -TimeoutS $TimeoutS
    exit $LASTEXITCODE
}

$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null
$Global:ModoTeste  = $true   # nao abrir o PDF/pasta no final do export

# fase 1 (rede local) simulada: nao mexe na placa de rede real da maquina de teste
$Global:FaseLocalSimulada = [pscustomobject]@{
    Host = 'NB-TESTE-01'
    Lan = [pscustomobject]@{
        presente = $true; nome = 'Ethernet'; descricao = 'Realtek PCIe GbE Family Controller'
        status = 'Up'; conectado = $true
        ipv4 = '192.168.15.42'; prefixo = 24; mascara = '255.255.255.0'; gateway = '192.168.15.1'
        dns = @('192.168.15.1', '8.8.8.8'); mac = 'AA-BB-CC-DD-EE-FF'; velocidade_mbps = 1000
    }
    Wireless = [pscustomobject]@{
        presente = $true; nome = 'Wi-Fi'; status = 'Disconnected'; conectado = $false
        ssid = ''; sinal_pct = $null; redes_disponiveis = @('JE-CAMPO', 'VIVO-2G')
    }
    Internet = [pscustomobject]@{
        ping_alvo = '8.8.8.8'
        ping_ok = $true; ping_latencia_ms = 22; ping_perda_pct = 0; ping_min_ms = 21; ping_max_ms = 24
        ping_saida = @(
            'Disparando 8.8.8.8 com 32 bytes de dados:'
            'Resposta de 8.8.8.8: bytes=32 tempo=21ms TTL=115'
            'Resposta de 8.8.8.8: bytes=32 tempo=24ms TTL=115'
            'Estatisticas do Ping para 8.8.8.8: Enviados = 4, Recebidos = 4, Perdidos = 0 (0% de perda)'
        )
        dns_nome = 'www.tre-ma.jus.br'
        dns_ok = $true; dns_ms = 35; dns_ips = @('200.1.1.1')
        download_url = 'https://speed.cloudflare.com/__down?bytes=8000000'
        download_ok = $true; download_mbps = 48.3; download_bytes = 8000000; download_seg = 1.3
    }
    Quando = (Get-Date).ToString('o')
}

Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Invoke-Pump {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        [action] { $frame.Continue = $false }) | Out-Null
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---- fixtures numa pasta temporaria: nao toca no data/ real -------------
$dataDir = Join-Path ([IO.Path]::GetTempPath()) ('dicon-teste-data-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$Global:PastaDadosOverride = $dataDir

$agora = (Get-Date).ToString('o')
@{ atualizado_em = $agora; juntas = @(
        @{ id = 'ZE99-TESTE-PRINCIPAL'; zona_eleitoral = 99; municipio_sede = 'TESTE'; municipio_termo = 'Teste'
            tipo = 'principal'; nome = 'LOCAL PRINCIPAL DE TESTE'; endereco = 'Rua Teste, 1'; tipo_internet = 'Fibra optica'
            unidade_consumidora = '10163145'; responsavel = 'Fulano de Tal'; funcao = 'Servidor'; telefone = '(99) 90000-0000'; texto_completo = '' }
        @{ id = 'ZE99-TESTE-CONTINGENCIA'; zona_eleitoral = 99; municipio_sede = 'TESTE'; municipio_termo = 'Teste'
            tipo = 'contingencia'; nome = 'LOCAL DE CONTINGENCIA DE TESTE'; endereco = 'Rua Teste, 2'; tipo_internet = 'Banda larga'; texto_completo = '' }
        @{ id = 'ZE88-FORA-PRINCIPAL'; zona_eleitoral = 88; municipio_sede = 'FORA'; municipio_termo = 'Fora da Rota'
            tipo = 'principal'; nome = 'LOCAL FORA DA ROTA'; endereco = 'Rua Fora, 1'; tipo_internet = 'Radio'; texto_completo = '' }
    ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dataDir 'juntas.json') -Encoding UTF8

@{ atualizado_em = $agora; tecnicos = @(
        @{ nome = 'TECNICO HEADLESS'; roteiro_numero = 99; roteiro_nome = 'Teste'; ida = '01/01/2026'; retorno = '02/01/2026'; dias = 2 }
    ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dataDir 'tecnicos.json') -Encoding UTF8

@{ atualizado_em = $agora; roteiros = @(
        @{ numero = 99; nome = 'Teste'; rotulo = 'Roteiro 99 - Teste'; tecnico = 'TECNICO HEADLESS'; etapa = 1
            ida = '01/01/2026'; retorno = '02/01/2026'; dias = 2; total_km = 10; total_tempo = '1h'; total_locais = 1
            cidades = @('Teste'); cidades_sem_junta = @()
            trechos = @(@{ origem = 'A'; destino = 'Teste'; distancia_km = 10; tempo = '1h'; atividade_dias = 0.5 })
            juntas_ids = @('ZE99-TESTE-PRINCIPAL', 'ZE99-TESTE-CONTINGENCIA') }
    ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dataDir 'roteiros.json') -Encoding UTF8

$pendDir = Join-Path $Global:RaizApp 'resultados\pendentes'
$pendAntes = @(Get-ChildItem $pendDir -Filter *.json -EA SilentlyContinue | Select-Object -ExpandProperty FullName)

$falhas = 0
try {
    $w = New-JanelaPrincipal
    Write-Host "[1] Janela construida"
    if ($w.FindName('viewLogin').Visibility -ne 'Visible') { Write-Host "    FALHA: nao abriu no login"; $falhas++ }
    else { Write-Host "[1] Abriu na tela de login" }

    # 2. login
    $cbo = $w.FindName('cboTecnico')
    if ($cbo.Items.Count -lt 1) { Write-Host "[2] FALHA: cboTecnico vazio"; $falhas++ }
    $cbo.SelectedIndex = 0
    Enter-Sessao
    if ($w.FindName('viewHome').Visibility -ne 'Visible') { Write-Host "[2] FALHA: nao foi para a home"; $falhas++ }
    else { Write-Host "[2] Login OK -> home ($($w.FindName('txtSaudacao').Text))" }

    # 2b. seletor de Juntas filtra pela rota do tecnico (cache tem 2, rota tem 1)
    $nJrota = @($w.FindName('cboJunta').ItemsSource).Count
    if ($nJrota -eq 1) { Write-Host "[2b] seletor filtra pela rota: $nJrota Junta (de 2 no cache)" }
    else { Write-Host "    FALHA: seletor mostrou $nJrota Junta(s) (esperado 1 da rota)"; $falhas++ }

    # 2c. 'incluir Juntas fora da rota' (admin) volta a mostrar todas
    $Global:MostrarTodasJuntas = $true;  Update-SeletorJuntas
    $nJtodas = @($w.FindName('cboJunta').ItemsSource).Count
    $Global:MostrarTodasJuntas = $false; Update-SeletorJuntas
    if ($nJtodas -eq 2) { Write-Host "[2c] incluir fora da rota: $nJtodas Juntas" }
    else { Write-Host "    FALHA: incluir fora da rota = $nJtodas (esperado 2)"; $falhas++ }

    # 3. guia de bordo
    Show-GuiaBordo
    if ($w.FindName('viewGuia').Visibility -ne 'Visible') { Write-Host "[3] FALHA: nao abriu o guia"; $falhas++ }
    $nTrechos = @($w.FindName('lstTrechos').ItemsSource).Count
    $nJuntas  = @($w.FindName('lstGuiaJuntas').ItemsSource).Count
    Write-Host "[3] Guia: $nTrechos trecho(s), $nJuntas grupo(s) de Junta"
    if ($nTrechos -lt 1 -or $nJuntas -lt 1) { Write-Host "    FALHA: guia sem conteudo"; $falhas++ }

    # 4. assistente pelo atalho do guia: abre no passo 1, Junta/Local pre-selecionados
    Start-DiagnosticoDoGuia -LocalId 'ZE99-TESTE-PRINCIPAL'
    Invoke-Pump
    if ($w.FindName('viewDiag').Visibility -ne 'Visible' -or $Global:WizardStep -ne 1) {
        Write-Host "[4] FALHA: nao abriu o assistente no passo 1 (step=$($Global:WizardStep))"; $falhas++
    }
    $selL = $w.FindName('cboLocal').SelectedItem
    if (-not $selL) { Write-Host "[4] FALHA: local nao pre-selecionado"; $falhas++ }
    else { Write-Host "[4] Assistente passo 1, local pre-selecionado: $($selL.Rotulo)" }

    # 4b. passo 1 -> 2: cartao de detalhe do local aparece com os campos extras
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 2) { Write-Host "[4b] FALHA: nao foi para o passo 2"; $falhas++ }
    if ($w.FindName('cardDetalheLocal').Visibility -ne 'Visible') { Write-Host "[4b] FALHA: cartao de detalhe nao apareceu"; $falhas++ }
    else { Write-Host "[4b] Passo 2: detalhe = '$($w.FindName('txtDetNome').Text)'" }
    $uc  = $w.FindName('txtDetUC')
    $rsp = $w.FindName('txtDetResponsavel')
    if ($uc.Visibility -eq 'Visible' -and "$($uc.Text)" -match '10163145' -and $rsp.Visibility -eq 'Visible' -and "$($rsp.Text)" -match 'Servidor') {
        Write-Host "[4b] campos extras: '$($uc.Text)' / '$($rsp.Text)'"
    } else { Write-Host "    FALHA: cartao sem UC/responsavel (uc='$($uc.Text)' resp='$($rsp.Text)')"; $falhas++ }

    # 4c. passo 2 -> 3 (rede local, sem VPN): probe ao entrar mostra as placas
    Invoke-WizardProximo
    Invoke-Pump
    if ($Global:WizardStep -ne 3) { Write-Host "[4c] FALHA: nao foi para o passo 3 (rede local)"; $falhas++ }
    $hostTxt = "$($w.FindName('txtLocHost').Text)"
    if ($w.FindName('cardFaseLocal').Visibility -eq 'Visible' -and
        $w.FindName('cardInternetLocal').Visibility -eq 'Collapsed' -and
        $w.FindName('btnRodarFaseLocal').IsEnabled -and $hostTxt -match 'NB-TESTE-01') {
        Write-Host "[4c] probe ao entrar: placas mostradas ($hostTxt), internet ainda nao testada"
    } else { Write-Host "    FALHA: probe do passo 3 (card=$($w.FindName('cardFaseLocal').Visibility) inet=$($w.FindName('cardInternetLocal').Visibility) rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled) host='$hostTxt')"; $falhas++ }

    # 4c-1. passo 3 bloqueia antes de rodar a checagem da internet do local
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 3) { Write-Host "[4c] FALHA: avancou sem testar a internet local"; $falhas++ }
    else { Write-Host "[4c] passo 3 bloqueia antes do teste de internet" }

    # 4c-2. roda a checagem (simulada): painel de internet aparece; avanca p/ passo 4
    Invoke-RodarFaseLocal
    Invoke-Pump
    $ipTxt = "$($w.FindName('txtLocIp').Text)"
    if ($null -ne $Global:FaseLocalPayload.Internet -and $ipTxt -match '192\.168\.15\.42' -and $w.FindName('cardInternetLocal').Visibility -eq 'Visible') {
        Write-Host "[4c] checagem local OK: '$ipTxt' + card de internet visivel"
    } else { Write-Host "    FALHA: checagem nao completou (internet=$($null -ne $Global:FaseLocalPayload.Internet) ip='$ipTxt' card=$($w.FindName('cardInternetLocal').Visibility))"; $falhas++ }
    $pingTxt = "$($w.FindName('txtPingSaida').Text)"
    $dlTxt   = "$($w.FindName('txtDownloadSaida').Text)"
    if ($pingTxt -match 'Resposta de 8\.8\.8\.8' -and $pingTxt -match 'tempo=21ms') {
        Write-Host "[4c] ping verboso linha a linha OK"
    } else { Write-Host "    FALHA: ping sem saida verbosa ('$pingTxt')"; $falhas++ }
    if ($dlTxt -match 'speed\.cloudflare\.com' -and $dlTxt -match 'MB') {
        Write-Host "[4c] download mostra alvo + tamanho: '$($dlTxt -replace "`n",' | ')'"
    } else { Write-Host "    FALHA: download sem alvo/tamanho ('$dlTxt')"; $falhas++ }
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 4) { Write-Host "    FALHA: nao foi para o passo 4 (diagnostico com VPN)"; $falhas++ }

    Show-WizardPasso 3

    # 4c-3. sem placa Wi-Fi -> some o card "Conectar a uma rede Wi-Fi"
    $Global:FaseLocalPayload.Wireless.presente = $false
    Update-PainelFaseLocal
    if ($w.FindName('cardConectarWifi').Visibility -eq 'Collapsed') { Write-Host "[4c] sem placa Wi-Fi: card de conexao some" }
    else { Write-Host "    FALHA: card Wi-Fi visivel sem placa"; $falhas++ }
    $Global:FaseLocalPayload.Wireless.presente = $true
    Update-PainelFaseLocal
    if ($w.FindName('cardConectarWifi').Visibility -eq 'Visible') { Write-Host "[4c] com placa Wi-Fi: card de conexao aparece" }
    else { Write-Host "    FALHA: card Wi-Fi oculto com placa"; $falhas++ }

    # 4c-3b. LAN conectada -> "teste pelo celular" fica DESABILITADO
    if (-not $w.FindName('chkTetheringCelular').IsEnabled) { Write-Host "[4c] com LAN conectada: 'teste pelo celular' desabilitado" }
    else { Write-Host "    FALHA: tethering habilitado com LAN conectada"; $falhas++ }

    # 4c-3c. conectar Wi-Fi sem SSID mostra aviso (nao chama netsh)
    $w.FindName('cboWifiSsid').Text = ''
    Invoke-ConectarWifi
    if ("$($w.FindName('txtWifiStatus').Text)" -match 'SSID') { Write-Host "[4c] conectar Wi-Fi exige SSID" }
    else { Write-Host "    FALHA: conectar Wi-Fi sem SSID nao avisou"; $falhas++ }

    # 4c-4. sem cabo LAN + com Wi-Fi -> "teste pelo celular" habilita e exige operadora
    $Global:FaseLocalPayload.Lan.conectado      = $false
    $Global:FaseLocalPayload.Wireless.conectado = $false
    Update-PainelFaseLocal
    if (-not $w.FindName('btnRodarFaseLocal').IsEnabled -and "$($w.FindName('txtLocDica').Visibility)" -eq 'Visible') {
        Write-Host "[4c] sem LAN e sem Wi-Fi conectado: checagem travada + dica visivel"
    } else { Write-Host "    FALHA: gate sem conexao (rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled) dica=$($w.FindName('txtLocDica').Visibility))"; $falhas++ }
    $Global:FaseLocalPayload.Wireless.conectado = $true
    Update-PainelFaseLocal
    if ($w.FindName('chkTetheringCelular').IsEnabled -and $w.FindName('btnRodarFaseLocal').IsEnabled) {
        Write-Host "[4c] sem LAN + Wi-Fi conectado: tethering habilita e a checagem libera"
    } else { Write-Host "    FALHA: gate sem LAN+wifi (tether.en=$($w.FindName('chkTetheringCelular').IsEnabled) rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled))"; $falhas++ }
    $w.FindName('chkTetheringCelular').IsChecked = $true
    Update-TetheringCelular
    if (-not $w.FindName('cboOperadora').IsEnabled) { Write-Host "    FALHA: campo Operadora nao habilitou"; $falhas++ }
    $w.FindName('cboOperadora').Text = ''
    Invoke-WizardProximo
    if ($Global:WizardStep -eq 3) { Write-Host "[4c] tethering marcado exige a operadora" }
    else { Write-Host "    FALHA: avancou com tethering sem operadora (step=$($Global:WizardStep))"; $falhas++ }
    $w.FindName('cboOperadora').Text = 'Vivo'
    $Global:FaseLocalPayload.Lan.conectado = $true   # restaura o fixture (compartilhado) p/ o JSON e proximos testes
    Invoke-WizardProximo
    if ($Global:WizardStep -eq 4) { Write-Host "[4c] com a operadora informada -> passo 4" }
    else { Write-Host "    FALHA: nao avancou com a operadora (step=$($Global:WizardStep))"; $falhas++ }

    # 4c-5. voltar ao passo 2 e retornar LIMPA a checagem e o tethering
    Invoke-WizardVoltar          # 4 -> 3
    Invoke-WizardVoltar          # 3 -> 2  (Update-DetalheLocal invalida a checagem)
    if ($null -eq $Global:FaseLocalPayload -and -not $w.FindName('chkTetheringCelular').IsChecked -and
        -not ([string] $w.FindName('cboOperadora').Text)) {
        Write-Host "[4c] voltar ao passo 2 limpa a ultima checagem e o tethering"
    } else { Write-Host "    FALHA: passo 2 nao limpou (payload=$($null -ne $Global:FaseLocalPayload) tether=$($w.FindName('chkTetheringCelular').IsChecked) op='$($w.FindName('cboOperadora').Text)')"; $falhas++ }
    Invoke-WizardProximo         # 2 -> 3: novo probe
    Invoke-Pump
    if ($Global:WizardStep -eq 3 -and $null -ne $Global:FaseLocalPayload -and $null -eq $Global:FaseLocalPayload.Internet) {
        Write-Host "[4c] re-entrou no passo 3 com checagem zerada"
    } else { Write-Host "    FALHA: re-probe ao voltar (step=$($Global:WizardStep))"; $falhas++ }
    # refaz o cenario "sem LAN, via celular": tethering + operadora + checagem
    $Global:FaseLocalPayload.Lan.conectado      = $false
    $Global:FaseLocalPayload.Wireless.conectado = $true    # conectado ao hotspot do celular
    Update-PainelFaseLocal
    $w.FindName('chkTetheringCelular').IsChecked = $true ; Update-TetheringCelular
    $w.FindName('cboOperadora').Text = 'Vivo'
    Invoke-RodarFaseLocal ; Invoke-Pump
    Invoke-WizardProximo         # 3 -> 4
    if ($Global:WizardStep -ne 4) { Write-Host "    FALHA: nao voltou ao passo 4 apos re-checagem (step=$($Global:WizardStep))"; $falhas++ }

    # 4d. passo 4 -> 5 bloqueia antes de rodar o diagnostico
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 4) { Write-Host "[4d] FALHA: avancou sem rodar o diagnostico"; $falhas++ }
    else { Write-Host "[4d] passo 4 bloqueia antes de rodar" }

    # 5. roda a bateria -> auto-avanca para o passo 5
    Invoke-ExecucaoNaJanela
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump
        Start-Sleep -Milliseconds 150
        if ($null -ne $Global:DiagPayload -and $w.FindName('btnRodar').IsEnabled) { $ok = $true; break }
    }
    Invoke-Pump
    $nLinhas = @($w.FindName('dgAvaliacao').ItemsSource).Count
    $decIni  = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    Write-Host "[5] Concluiu: $ok | passo: $($Global:WizardStep) | painel: $nLinhas linhas | decisao: $decIni"
    if (-not $ok) { $falhas++ }
    if ($Global:WizardStep -ne 5) { Write-Host "    FALHA: nao auto-avancou para o passo 5"; $falhas++ }
    if ($nLinhas -ne 6) { Write-Host "    FALHA: painel deveria ter 6 linhas"; $falhas++ }
    if ($decIni -notin @('viavel', 'viavel_com_ressalva', 'inviavel')) { Write-Host "    FALHA: decisao nao classificou"; $falhas++ }

    # 5b. override de metrica + passo 5 -> 6 bloqueia sem justificativa
    $linha = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    $linha.ClasseFinal = 'viavel'
    Invoke-Pump
    Invoke-WizardProximo
    $ultimoLog = @($Global:LogEntries)[-1].Texto
    if ($Global:WizardStep -eq 5 -and $ultimoLog -match 'Justificativa obrigatoria') {
        Write-Host "[5b] passo 5 bloqueia override sem justificativa"
    } else { Write-Host "    FALHA: passo 5 avancou sem justificativa (step=$($Global:WizardStep))"; $falhas++ }

    # 5c. com justificativa -> passos 5 -> 6 -> 7
    $linha.Justificativa = 'Refiz o teste pelo celular e deu 25 Mbps.'
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 6) { Write-Host "    FALHA: nao foi para o passo 6"; $falhas++ }
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 7) { Write-Host "    FALHA: nao foi para o passo 7"; $falhas++ }
    else { Write-Host "[5c] passos 5->6->7 com justificativa" }

    # 5d. passo 6: salva o resultado -> checklist "Salvar" fica verde, "Transmitir" habilita
    $antesJson = @(Get-ChildItem (Join-Path $Global:RaizApp 'resultados\pendentes') -Filter *.json -EA SilentlyContinue).Count
    Invoke-SalvarResultado
    $novos = @(Get-ChildItem (Join-Path $Global:RaizApp 'resultados\pendentes') -Filter *.json -EA SilentlyContinue)
    if ($novos.Count -le $antesJson) { Write-Host "    FALHA: nao gravou o JSON"; $falhas++ }
    else {
        $doc = Get-Content ($novos | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $linhaAlt = $doc.avaliacao | Where-Object { $_.ajustada } | Select-Object -First 1
        $okDoc = ($doc.tecnico.nome) -and ($doc.classificacao.final) -and $linhaAlt -and $linhaAlt.justificativa
        Write-Host "[5d] salvo: tecnico='$($doc.tecnico.nome)' final='$($doc.classificacao.final)' ajustada='$($linhaAlt.metrica)'->'$($linhaAlt.classe_final)'"
        if (-not $okDoc) { Write-Host "    FALHA: JSON incompleto"; $falhas++ }
        $rl = $doc.rede_local
        if ($rl -and $rl.ip_local -eq '192.168.15.42' -and $rl.gateway -eq '192.168.15.1' -and $rl.host -eq 'NB-TESTE-01' -and
            @($rl.wireless_redes).Count -ge 1 -and $rl.internet_ping_alvo -eq '8.8.8.8' -and "$($rl.internet_download_url)" -match 'cloudflare') {
            Write-Host "[5d] JSON traz rede_local: host=$($rl.host) ip=$($rl.ip_local) ping_alvo=$($rl.internet_ping_alvo) dl_url=ok"
        } else { Write-Host "    FALHA: JSON sem bloco rede_local completo (host='$($rl.host)' ip='$($rl.ip_local)' alvo='$($rl.internet_ping_alvo)')"; $falhas++ }
        if ($rl.tethering_celular -eq $true -and $rl.operadora -eq 'Vivo') {
            Write-Host "[5d] rede_local traz o tethering: operadora=$($rl.operadora)"
        } else { Write-Host "    FALHA: rede_local sem tethering/operadora (t=$($rl.tethering_celular) op='$($rl.operadora)')"; $falhas++ }
    }
    $vok = [char]0x2713
    if ($Global:FeitoSalvar -and "$($w.FindName('chkFimSalvar').Text)" -eq $vok -and $w.FindName('btnTransmitirResultado').IsEnabled -and "$($w.FindName('chkFimTransmitir').Text)" -ne $vok) {
        Write-Host "[5d] checklist: Salvar=OK, Transmitir habilitado e pendente"
    } else { Write-Host "    FALHA: checklist do passo 6 (salvar=$($Global:FeitoSalvar) transmitir.en=$($w.FindName('btnTransmitirResultado').IsEnabled))"; $falhas++ }

    # 5d-2. exporta o relatorio pelo botao -> checklist "Exportar" fica verde
    Invoke-ExportarRelatorio
    if ($Global:FeitoExportar -and "$($w.FindName('chkFimExportar').Text)" -eq $vok -and "$($w.FindName('txtFimStatus').Text)" -match 'Relatorio salvo') {
        Write-Host "[5d] relatorio exportado ($($w.FindName('txtFimStatus').Text))"
    } else { Write-Host "    FALHA: export nao marcou o checklist (exportar=$($Global:FeitoExportar))"; $falhas++ }

    # 5e. acompanhamento: guia marca o local como testado; home mostra progresso
    Show-GuiaBordo
    $grpT = @($w.FindName('lstGuiaJuntas').ItemsSource)[0]
    $locT = @($grpT.locais) | Where-Object { $_.id -eq 'ZE99-TESTE-PRINCIPAL' } | Select-Object -First 1
    if ($locT -and "$($locT.TesteStatus)" -match 'Testado' -and "$($locT.BotaoRodar)" -match 'Refazer') {
        Write-Host "[5e] guia marca o local como testado: '$($locT.TesteStatus)'"
    } else {
        Write-Host "    FALHA: guia nao marcou o local como testado (status='$($locT.TesteStatus)')"; $falhas++
    }
    $prog = Get-ProgressoRoteiro -Roteiro $Global:RoteiroAtual -TecnicoNome 'TECNICO HEADLESS'
    if ($prog.Testados -eq 1 -and $prog.Total -eq 2) { Write-Host "[5e] progresso do roteiro: $($prog.Testados)/$($prog.Total)" }
    else { Write-Host "    FALHA: progresso $($prog.Testados)/$($prog.Total) (esperado 1/2)"; $falhas++ }

    # 6. menu Inicio -> assistente abre limpo no passo 1
    Open-DiagnosticoLimpo
    $selLimpo    = $w.FindName('cboLocal').SelectedItem
    $painelLimpo = ($w.FindName('dgAvaliacao').Items.Count -eq 0) -and ($null -eq $Global:DiagPayload)
    $faseLimpa   = ($null -eq $Global:FaseLocalPayload) -and ($w.FindName('cardFaseLocal').Visibility -ne 'Visible')
    if ($selLimpo -or $Global:LogEntries.Count -ne 0 -or -not $painelLimpo -or -not $faseLimpa -or $Global:WizardStep -ne 1) {
        Write-Host "[6] FALHA: nao abriu limpo (sel=$([bool]$selLimpo) log=$($Global:LogEntries.Count) painel=$($w.FindName('dgAvaliacao').Items.Count) payload=$($null -ne $Global:DiagPayload) fase=$($null -ne $Global:FaseLocalPayload) step=$($Global:WizardStep))"
        $falhas++
    } else { Write-Host "[6] Assistente pelo menu abre limpo no passo 1 (rede local zerada)" }

    # 6b. passo 2 com local JA testado: some "Proximo", aparece "Refazer o teste"
    Show-WizardPasso 2
    $cboJ6 = $w.FindName('cboJunta'); if ($cboJ6.Items.Count) { $cboJ6.SelectedIndex = 0 }
    $cboL6 = $w.FindName('cboLocal')
    $liP = @($cboL6.Items) | Where-Object { $_.Dados.id -eq 'ZE99-TESTE-PRINCIPAL' } | Select-Object -First 1
    $liC = @($cboL6.Items) | Where-Object { $_.Dados.id -eq 'ZE99-TESTE-CONTINGENCIA' } | Select-Object -First 1
    $cboL6.SelectedItem = $liC; Invoke-Pump          # nao testado
    $cboL6.SelectedItem = $liP; Invoke-Pump          # testado no passo 5d
    $refV  = "$($w.FindName('btnRefazerTeste').Visibility)"
    $proxV = "$($w.FindName('btnWizProximo').Visibility)"
    if ($refV -eq 'Visible' -and $proxV -ne 'Visible') { Write-Host "[6b] local testado: 'Refazer o teste' no card, sem 'Proximo'" }
    else { Write-Host "    FALHA: nav passo 2 p/ testado (refazer=$refV proximo=$proxV)"; $falhas++ }
    $cboL6.SelectedItem = $liC; Invoke-Pump          # volta para nao testado
    if ("$($w.FindName('btnWizProximo').Visibility)" -eq 'Visible' -and "$($w.FindName('btnRefazerTeste').Visibility)" -ne 'Visible') { Write-Host "[6b] local nao testado: 'Proximo' de volta" }
    else { Write-Host "    FALHA: nav nao voltou p/ nao testado"; $falhas++ }
    $cboL6.SelectedItem = $liP; Invoke-Pump
    Invoke-WizardProximo                              # o handler de 'Refazer o teste'
    if ($Global:WizardStep -eq 3) { Write-Host "[6b] 'Refazer o teste' -> passo 3 (rede local)" }
    else { Write-Host "    FALHA: refazer nao foi ao passo 3 (step=$($Global:WizardStep))"; $falhas++ }

    # 7. trocar usuario
    Invoke-TrocarUsuario
    if ($w.FindName('viewLogin').Visibility -ne 'Visible') { Write-Host "[7] FALHA: 'trocar usuario' nao voltou ao login"; $falhas++ }
    else { Write-Host "[7] Trocar usuario -> login OK" }

    # 8. admin: tela de limiares (sem POST real)
    Set-Sessao -TecnicoNome $Global:AdminNome -Papel 'admin' | Out-Null
    Enter-Home -Sessao (Get-Sessao)
    if ($w.FindName('btnMenuAdmin').Visibility -ne 'Visible') { Write-Host "[8] FALHA: botao Administracao nao aparece para admin"; $falhas++ }
    if ($w.FindName('chkTodasJuntas').Visibility -ne 'Collapsed') { Write-Host "    FALHA: checkbox 'incluir Juntas fora da rota' deveria estar oculto"; $falhas++ }
    else { Write-Host "[8] checkbox 'incluir Juntas fora da rota' oculto (desativado por ora)" }
    Show-Admin
    $nLim = $w.FindName('dgLimiares').Items.Count
    Write-Host "[8] Admin: $nLim linha(s) de limiar"
    if ($nLim -ne 6) { Write-Host "    FALHA: deveria ter 6 metricas"; $falhas++ }
    if ($Global:LimiarRows[0].Ativo -ne $true) { Write-Host "    FALHA: limiar sem 'Na bateria' marcado por padrao"; $falhas++ }
    else { Write-Host "[8] limiar vem com 'Na bateria' marcado" }
    $w.FindName('txtPinAdmin').Password = ''
    Invoke-SalvarLimiares
    if ($w.FindName('lblAdminMsg').Text -notmatch 'PIN') { Write-Host "    FALHA: salvou limiares sem PIN"; $falhas++ }
    else { Write-Host "[8] salvar limiares sem PIN bloqueado" }

    # 9. metrica desativada sai da bateria (motor)
    $limTest = [pscustomobject]@{
        latencia_ms         = [pscustomobject]@{ viavel_ate = 60; ressalva_ate = 120; ativo = $true }
        jitter_ms           = [pscustomobject]@{ viavel_ate = 10; ressalva_ate = 30;  ativo = $true }
        perda_percentual    = [pscustomobject]@{ viavel_ate = 1;  ressalva_ate = 5;   ativo = $true }
        banda_download_mbps = [pscustomobject]@{ viavel_min = 20; ressalva_min = 8;   ativo = $true }
        banda_upload_mbps   = [pscustomobject]@{ viavel_min = 10; ressalva_min = 4;   ativo = $true }
        carregamento_web_s  = [pscustomobject]@{ viavel_ate = 5;  ressalva_ate = 12;  ativo = $false }
    }
    $met = [pscustomobject]@{ LatenciaMediaMs = 10; JitterMs = 1; PerdaPercentual = 0; BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = $null }
    $dec = Invoke-MotorDecisao -Metricas $met -Limiares $limTest
    if (@($dec.Detalhes).Count -eq 5 -and (@($dec.MetricasDesativadas) -contains 'carregamento_web_s') -and $dec.Classificacao -eq 'viavel') {
        Write-Host "[9] metrica desativada fora da bateria (5 detalhes, decisao=viavel)"
    } else {
        Write-Host "    FALHA: motor c/ metrica desativada (detalhes=$(@($dec.Detalhes).Count) desat=$($dec.MetricasDesativadas -join ',') dec=$($dec.Classificacao))"; $falhas++
    }
}
finally {
    $Global:PastaDadosOverride = $null
    $Global:FaseLocalSimulada  = $null
    Remove-Item $dataDir -Recurse -Force -EA SilentlyContinue
    # remove os JSON de resultado criados por este teste
    Get-ChildItem $pendDir -Filter *.json -EA SilentlyContinue |
        Where-Object { $_.FullName -notin $pendAntes } |
        Remove-Item -Force -EA SilentlyContinue
    Get-ChildItem (Join-Path $Global:RaizApp 'relatorios') -Filter '*.*' -EA SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Force -EA SilentlyContinue
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: OK"; exit 0 }
else { Write-Host "RESULTADO: $falhas FALHA(S)"; exit 1 }
