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
$Global:VpnSimulada = $true  # passo 4: VPN "conectada" (troque p/ testar o gate)

# fase 1 (rede local) simulada: nao mexe na placa de rede real da maquina de teste
$Global:FaseLocalSimulada = [pscustomobject]@{
    Host = 'NB-TESTE-01'
    Lan = [pscustomobject]@{
        presente = $true; nome = 'Ethernet'; descricao = 'Realtek PCIe GbE Family Controller'
        status = 'Up'; conectado = $true
        ipv4 = '192.168.15.42'; prefixo = 24; mascara = '255.255.255.0'; gateway = '192.168.15.1'
        dns = @('192.168.15.1', '8.8.8.8'); ip_origem = 'DHCP'; mac = 'AA-BB-CC-DD-EE-FF'; velocidade_mbps = 1000
    }
    Wireless = [pscustomobject]@{
        presente = $true; nome = 'Wi-Fi'; status = 'Disconnected'; conectado = $false
        ssid = ''; sinal_pct = $null; redes_disponiveis = @('JE-CAMPO', 'VIVO-2G')
        ipv4 = '192.168.15.42'; prefixo = 24; mascara = '255.255.255.0'; gateway = '192.168.15.1'
        dns = @('192.168.15.1'); ip_origem = 'DHCP'; mac = '11-22-33-44-55-66'; velocidade_mbps = 300
    }
    Internet = [pscustomobject]@{
        speedtest_ok = $true; speedtest_erro = ''
        isp = 'BARREIRAS NET'; ip_externo = '187.62.154.178'
        servidor_nome = 'Suprinet Fibra'; servidor_local = 'Corrente'; servidor_id = 12345; servidor_host = 'st.suprinet.net:8080'
        ping_ms = 20.1; jitter_ms = 0.8; perda_pct = 0.0
        download_mbps = 855.63; upload_mbps = 295.27; download_lat_ms = 27; upload_lat_ms = 20
        resultado_url = 'https://www.speedtest.net/result/c/abc-123'; resultado_id = 'abc-123'
        quando = (Get-Date).ToString('o')
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

    # 2d. menu lateral recolhe/expande
    $lRail0 = $w.FindName('railNav').Width
    Invoke-ToggleRail
    $lRail1 = $w.FindName('railNav').Width
    if ($lRail1 -lt $lRail0 -and "$($w.FindName('lblNavGuia').Visibility)" -eq 'Collapsed') {
        Write-Host "[2d] menu recolheu ($lRail0 -> $lRail1, rotulos ocultos)"
    } else { Write-Host "    FALHA: menu nao recolheu (w $lRail0 -> $lRail1)"; $falhas++ }
    Invoke-ToggleRail
    if ($w.FindName('railNav').Width -eq $lRail0 -and "$($w.FindName('lblNavGuia').Visibility)" -eq 'Visible') {
        Write-Host "[2d] menu expandiu de volta"
    } else { Write-Host "    FALHA: menu nao expandiu"; $falhas++ }

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
    $nJuntas  = @($w.FindName('lstGuiaJuntas').ItemsSource).Count
    Write-Host "[3] Guia: $nJuntas grupo(s) de Junta"
    if ($nJuntas -lt 1) { Write-Host "    FALHA: guia sem conteudo"; $falhas++ }

    # 3b. tela de Locais: lista + busca + filtros por ZE/municipio
    Show-Locais
    if ($w.FindName('viewLocais').Visibility -eq 'Visible' -and @($w.FindName('dgLocais').ItemsSource).Count -ge 1) {
        $nTot = @($w.FindName('dgLocais').ItemsSource).Count
        Write-Host "[3b] Locais: tela abriu com $nTot local(is)"
    } else { Write-Host "[3b] FALHA: tela de Locais vazia (vis=$($w.FindName('viewLocais').Visibility))"; $falhas++ }
    $nTodos = @($w.FindName('dgLocais').ItemsSource).Count
    $w.FindName('txtBuscaLocais').Text = 'zzz-nao-existe'
    Invoke-Pump
    if (@($w.FindName('dgLocais').ItemsSource).Count -eq 0) { Write-Host "[3b] busca sem resultado filtra a grade" }
    else { Write-Host "    FALHA: busca nao filtrou"; $falhas++ }
    $w.FindName('txtBuscaLocais').Text = ''
    Invoke-Pump
    if (@($w.FindName('dgLocais').ItemsSource).Count -eq $nTodos) { Write-Host "[3b] limpar a busca restaura a lista" }
    else { Write-Host "    FALHA: limpar a busca nao restaurou ($(@($w.FindName('dgLocais').ItemsSource).Count) x $nTodos)"; $falhas++ }
    if (@($w.FindName('cboFiltroZE').ItemsSource).Count -ge 2 -and @($w.FindName('cboFiltroMun').ItemsSource).Count -ge 2) {
        Write-Host "[3b] combos ZE/municipio populados"
    } else { Write-Host "    FALHA: combos de filtro vazios"; $falhas++ }
    $w.FindName('dgLocais').SelectedIndex = 0
    Invoke-Pump
    if ("$($w.FindName('cardLocalDetalhe').Visibility)" -eq 'Visible' -and "$($w.FindName('txtLocDetNome').Text)") {
        Write-Host "[3b] selecionar um local mostra o cartao de detalhe"
    } else { Write-Host "    FALHA: cartao de detalhe do local nao apareceu"; $falhas++ }
    Show-View 'viewHome'

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
        -not $w.FindName('btnRodarFaseLocal').IsEnabled -and $hostTxt -match 'NB-TESTE-01') {
        Write-Host "[4c] probe ao entrar: placas mostradas ($hostTxt); 'Rodar checagem' travado ate escolher a placa"
    } else { Write-Host "    FALHA: probe do passo 3 (card=$($w.FindName('cardFaseLocal').Visibility) inet=$($w.FindName('cardInternetLocal').Visibility) rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled) host='$hostTxt')"; $falhas++ }

    # 4c-0b. botao "reler placas" reinventaria sem sair do passo 3
    $antHost = "$($w.FindName('txtLocHost').Text)"
    Invoke-RelerPlacas
    Invoke-Pump
    if ($Global:WizardStep -eq 3 -and $w.FindName('cardFaseLocal').Visibility -eq 'Visible' -and
        "$($w.FindName('txtLocHost').Text)" -eq $antHost) {
        Write-Host "[4c] 'reler placas' reinventaria e mantem o passo 3"
    } else { Write-Host "    FALHA: 'reler placas' (step=$($Global:WizardStep) card=$($w.FindName('cardFaseLocal').Visibility))"; $falhas++ }

    # 4c-0. escolher a placa cabeada (LAN) libera "Rodar checagem local"
    $w.FindName('rbUsarLan').IsChecked = $true
    Invoke-Pump
    if ($w.FindName('rbUsarLan').IsEnabled -and $w.FindName('rbUsarWifi').IsEnabled -and
        $w.FindName('btnRodarFaseLocal').IsEnabled -and $Global:FaseLocalTipo -eq 'lan') {
        Write-Host "[4c] escolhida a placa LAN -> 'Rodar checagem local' libera"
    } else { Write-Host "    FALHA: escolha da placa (rbLan.en=$($w.FindName('rbUsarLan').IsEnabled) rbWifi.en=$($w.FindName('rbUsarWifi').IsEnabled) rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled) tipo='$($Global:FaseLocalTipo)')"; $falhas++ }

    # 4c-1. passo 3 bloqueia "Proximo" antes de rodar a checagem da internet do local
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 3) { Write-Host "[4c] FALHA: avancou sem testar a internet local"; $falhas++ }
    else { Write-Host "[4c] passo 3 bloqueia antes do teste de internet" }

    # 4c-2. roda o speedtest (simulado): velocimetro + painel de resultado; avanca p/ passo 4
    Invoke-RodarFaseLocal
    Invoke-Pump
    if ($Global:FaseLocalPayload.PSObject.Properties['TipoUsado'] -and $Global:FaseLocalPayload.TipoUsado -eq 'lan') {
        Write-Host "[4c] checagem registrou a placa usada: LAN"
    } else { Write-Host "    FALHA: TipoUsado nao gravado ('$($Global:FaseLocalPayload.TipoUsado)')"; $falhas++ }
    $it = $Global:FaseLocalPayload.Internet
    if ($it -and $it.speedtest_ok -and $w.FindName('cardInternetLocal').Visibility -eq 'Visible' -and
        "$($w.FindName('painelSpeedResultado').Visibility)" -eq 'Visible') {
        Write-Host "[4c] speedtest OK: card + painel de resultado visiveis"
    } else { Write-Host "    FALHA: speedtest nao completou (ok=$($it.speedtest_ok) card=$($w.FindName('cardInternetLocal').Visibility) painel=$($w.FindName('painelSpeedResultado').Visibility))"; $falhas++ }
    $rd = "$($w.FindName('runResDown').Text)"; $rp = "$($w.FindName('runConnProvedor').Text)"
    if ($rd -match '85' -and "$($w.FindName('runResUp').Text)" -match '29' -and $rp -match 'BARREIRAS NET') {
        Write-Host "[4c] resultado: down=$rd Mbps  up=$($w.FindName('runResUp').Text)  provedor='$rp'"
    } else { Write-Host "    FALHA: painel de resultado do speedtest (down='$rd' isp='$rp')"; $falhas++ }
    if ("$($w.FindName('txtVeloNum').Text)" -match '85' -and "$($w.FindName('txtVeloFase').Text)" -match 'concluido') {
        Write-Host "[4c] velocimetro fixou o download ($($w.FindName('txtVeloNum').Text) Mbps)"
    } else { Write-Host "    FALHA: velocimetro final (num='$($w.FindName('txtVeloNum').Text)' fase='$($w.FindName('txtVeloFase').Text)')"; $falhas++ }
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

    # 4c-3c. escolher "Usar o Wi-Fi do local" habilita o card de conexao; sem SSID avisa
    $w.FindName('rbUsarWifi').IsChecked = $true
    Invoke-Pump
    if ($w.FindName('cardConectarWifi').IsEnabled -and $Global:FaseLocalTipo -eq 'wifi') {
        Write-Host "[4c] escolher 'Usar o Wi-Fi do local' habilita o card 'Conectar a uma rede Wi-Fi'"
    } else { Write-Host "    FALHA: card Wi-Fi nao habilitou ao escolher (en=$($w.FindName('cardConectarWifi').IsEnabled) tipo='$($Global:FaseLocalTipo)')"; $falhas++ }
    $w.FindName('cboWifiSsid').Text = ''
    Invoke-ConectarWifi
    if ("$($w.FindName('txtWifiStatus').Text)" -match 'SSID') { Write-Host "[4c] conectar Wi-Fi exige SSID" }
    else { Write-Host "    FALHA: conectar Wi-Fi sem SSID nao avisou"; $falhas++ }

    # 4c-4. Wi-Fi escolhido mas nao conectado -> checagem travada; ao conectar, libera
    $Global:FaseLocalPayload.Lan.conectado      = $false
    $Global:FaseLocalPayload.Wireless.conectado = $false
    Update-PainelFaseLocal
    if (-not $w.FindName('btnRodarFaseLocal').IsEnabled -and "$($w.FindName('txtLocDica').Visibility)" -eq 'Visible') {
        Write-Host "[4c] Wi-Fi escolhido e nao conectado: checagem travada + dica visivel"
    } else { Write-Host "    FALHA: gate sem conexao (rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled) dica=$($w.FindName('txtLocDica').Visibility))"; $falhas++ }
    $Global:FaseLocalPayload.Wireless.conectado = $true
    Update-PainelFaseLocal
    if ($w.FindName('btnRodarFaseLocal').IsEnabled) {
        Write-Host "[4c] sem LAN + Wi-Fi do local conectado: checagem libera"
    } else { Write-Host "    FALHA: gate Wi-Fi do local (rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled))"; $falhas++ }

    # 4c-4b. meio "Celular": exige operadora
    $w.FindName('rbUsarCelular').IsChecked = $true
    Invoke-Pump
    $w.FindName('cboOperadoraCel').Text = ''
    Update-PainelFaseLocal
    if (-not $w.FindName('btnRodarFaseLocal').IsEnabled) { Write-Host "[4c] meio Celular sem operadora: checagem travada" }
    else { Write-Host "    FALHA: Celular liberou sem operadora"; $falhas++ }
    Invoke-WizardProximo
    if ($Global:WizardStep -eq 3) { Write-Host "[4c] Celular sem operadora nao avanca" }
    else { Write-Host "    FALHA: avancou sem operadora (step=$($Global:WizardStep))"; $falhas++ }
    $w.FindName('cboOperadoraCel').Text = 'Vivo'
    Set-FaseLocalTipo 'celular'
    Invoke-Pump
    if ($w.FindName('btnRodarFaseLocal').IsEnabled -and $Global:FaseLocalTipo -eq 'celular') {
        Write-Host "[4c] Celular + Wi-Fi conectado + operadora -> checagem libera"
    } else { Write-Host "    FALHA: Celular nao liberou (rodar.en=$($w.FindName('btnRodarFaseLocal').IsEnabled) tipo='$($Global:FaseLocalTipo)')"; $falhas++ }

    # 4c-4c. "nao aplicavel": marca a LAN e ela some da escolha
    $w.FindName('chkNaLan').IsChecked = $true
    $w.FindName('txtMotivoNaMeio').Text = 'sem ponto de rede na sala'
    Update-NaoAplicavelMeio
    if ($Global:MeiosNaoAplicaveis.ContainsKey('lan') -and -not $w.FindName('rbUsarLan').IsEnabled) {
        Write-Host "[4c] LAN marcada 'nao aplicavel' -> radio desabilitado"
    } else { Write-Host "    FALHA: 'nao aplicavel' nao pegou (chave=$($Global:MeiosNaoAplicaveis.ContainsKey('lan')) rb.en=$($w.FindName('rbUsarLan').IsEnabled))"; $falhas++ }
    $w.FindName('chkNaLan').IsChecked = $false ; Update-NaoAplicavelMeio

    # volta para Wi-Fi do local e avanca
    $Global:FaseLocalPayload.Lan.conectado = $true   # restaura o fixture
    $w.FindName('rbUsarWifi').IsChecked = $true
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -eq 4) { Write-Host "[4c] Wi-Fi do local -> passo 4" }
    else { Write-Host "    FALHA: nao avancou (step=$($Global:WizardStep))"; $falhas++ }

    # 4c-5. voltar ao passo 2 e retornar LIMPA a checagem e os meios
    Invoke-WizardVoltar          # 4 -> 3
    Invoke-WizardVoltar          # 3 -> 2  (Update-DetalheLocal invalida a checagem)
    if ($null -eq $Global:FaseLocalPayload -and [string]::IsNullOrEmpty($Global:FaseLocalTipo)) {
        Write-Host "[4c] voltar ao passo 2 limpa a ultima checagem"
    } else { Write-Host "    FALHA: passo 2 nao limpou (payload=$($null -ne $Global:FaseLocalPayload) tipo='$($Global:FaseLocalTipo)')"; $falhas++ }
    Invoke-WizardProximo         # 2 -> 3: novo probe
    Invoke-Pump
    if ($Global:WizardStep -eq 3 -and $null -ne $Global:FaseLocalPayload -and $null -eq $Global:FaseLocalPayload.Internet) {
        Write-Host "[4c] re-entrou no passo 3 com checagem zerada"
    } else { Write-Host "    FALHA: re-probe ao voltar (step=$($Global:WizardStep))"; $falhas++ }
    # refaz "via celular": escolhe o meio Celular + operadora + checagem
    $Global:FaseLocalPayload.Lan.conectado      = $false
    $Global:FaseLocalPayload.Wireless.conectado = $true    # conectado ao hotspot do celular
    Update-PainelFaseLocal
    $w.FindName('cboOperadoraCel').Text = 'Vivo'
    $w.FindName('rbUsarCelular').IsChecked = $true
    Set-FaseLocalTipo 'celular'
    Invoke-Pump
    Invoke-RodarFaseLocal ; Invoke-Pump
    Invoke-WizardProximo         # 3 -> 4
    if ($Global:WizardStep -ne 4) { Write-Host "    FALHA: nao voltou ao passo 4 apos re-checagem (step=$($Global:WizardStep))"; $falhas++ }

    # 4d. sem VPN: "Rodar diagnostico" desabilitado + botao do FortiClient visivel + rodar bloqueado
    $Global:VpnSimulada = $false ; Update-EstadoVpn
    if (-not $w.FindName('btnRodar').IsEnabled -and "$($w.FindName('btnAbrirFortiClient').Visibility)" -eq 'Visible' -and
        "$($w.FindName('txtDiagVpn').Text)" -match 'FortiClient') {
        Write-Host "[4d] sem VPN: 'Rodar diagnostico' travado + 'Abrir o FortiClient' visivel"
    } else { Write-Host "    FALHA: gate de VPN (rodar.en=$($w.FindName('btnRodar').IsEnabled) forti=$($w.FindName('btnAbrirFortiClient').Visibility))"; $falhas++ }
    Invoke-ExecucaoNaJanela
    if ($null -eq $Global:DiagRunState -and $null -eq $Global:DiagPayload) { Write-Host "[4d] sem VPN: 'Rodar diagnostico' nao inicia a bateria" }
    else { Write-Host "    FALHA: rodou o diagnostico sem VPN (runstate=$($null -ne $Global:DiagRunState))"; $falhas++ }

    # 4d-1. "Proximo" no passo 4 fica DESABILITADO ate rodar (ou marcar "VPN impossivel" + motivo)
    if (-not $w.FindName('btnWizProximo').IsEnabled) { Write-Host "[4d] 'Proximo' desabilitado sem diagnostico" }
    else { Write-Host "    FALHA: 'Proximo' habilitado sem rodar o diagnostico"; $falhas++ }
    $w.FindName('chkVpnImpossivel').IsChecked = $true ; Update-VpnImpossivel
    if ("$($w.FindName('txtVpnMotivo').Visibility)" -eq 'Visible' -and -not $w.FindName('btnWizProximo').IsEnabled) {
        Write-Host "[4d] marcou 'VPN impossivel' sem motivo: 'Proximo' segue desabilitado"
    } else { Write-Host "    FALHA: 'Proximo' habilitou sem o motivo da VPN"; $falhas++ }
    $w.FindName('txtVpnMotivo').Text = 'FortiClient corrompido; sem internet no local para reinstalar.'
    Update-Passo4Nav
    if ($w.FindName('btnWizProximo').IsEnabled) { Write-Host "[4d] motivo preenchido: 'Proximo' habilita" }
    else { Write-Host "    FALHA: 'Proximo' nao habilitou com o motivo"; $falhas++ }
    Set-DiagnosticoVpnImpossivel -Motivo ([string] $w.FindName('txtVpnMotivo').Text)
    if (@($Global:DiagPayload.Decisao.Detalhes).Count -eq 6 -and $Global:DiagPayload.Decisao.Classificacao -eq 'inviavel') {
        Write-Host "[4d] 'VPN impossivel' -> payload sintetico INVIAVEL (6 metricas sem medida)"
    } else { Write-Host "    FALHA: payload sintetico da VPN impossivel (det=$(@($Global:DiagPayload.Decisao.Detalhes).Count) cls=$($Global:DiagPayload.Decisao.Classificacao))"; $falhas++ }
    $w.FindName('chkVpnImpossivel').IsChecked = $false ; Update-VpnImpossivel
    Clear-PainelResultado

    $Global:VpnSimulada = $true ; Update-EstadoVpn
    if ($w.FindName('btnRodar').IsEnabled -and "$($w.FindName('btnAbrirFortiClient').Visibility)" -eq 'Collapsed') {
        Write-Host "[4d] com VPN: 'Rodar diagnostico' habilita, botao do FortiClient some"
    } else { Write-Host "    FALHA: VPN conectada nao liberou o rodar"; $falhas++ }

    # 4e. passo 4 -> 5 bloqueia antes de rodar o diagnostico
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 4) { Write-Host "[4e] FALHA: avancou sem rodar o diagnostico"; $falhas++ }
    else { Write-Host "[4e] passo 4 bloqueia antes de rodar" }

    # 5. roda a bateria -> NAO avanca sozinho; o tecnico clica em Proximo
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
    Write-Host "[5] Concluiu: $ok | passo: $($Global:WizardStep) | painel: $nLinhas linhas"
    if (-not $ok) { $falhas++ }
    if ($Global:WizardStep -ne 4) { Write-Host "    FALHA: avancou sozinho apos rodar (esperado ficar no passo 4)"; $falhas++ }
    else { Write-Host "[5] apos rodar continua no passo 4 (sem auto-avancar)" }
    if ($w.FindName('btnWizProximo').IsEnabled) { Write-Host "[5] apos rodar, 'Proximo' habilita" }
    else { Write-Host "    FALHA: 'Proximo' seguiu desabilitado apos rodar o diagnostico"; $falhas++ }
    # card do iperf3 aparece; sem o binario em bin\iperf3\ mostra o erro
    if ($w.FindName('cardIperfVpn').Visibility -eq 'Visible' -and "$($w.FindName('txtIperfErro').Text)" -match 'iperf3\.exe') {
        Write-Host "[5] card iperf3 (Fase 2) visivel; sem binario -> erro exibido"
    } else { Write-Host "    FALHA: card/erro do iperf3 (vis=$($w.FindName('cardIperfVpn').Visibility) erro='$($w.FindName('txtIperfErro').Text)')"; $falhas++ }
    Invoke-WizardProximo
    $decIni = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    if ($Global:WizardStep -ne 5) { Write-Host "    FALHA: Proximo nao foi para o passo 5"; $falhas++ }
    else { Write-Host "[5] Proximo -> passo 5 | decisao: $decIni" }
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

    # 5b-2. multi-meio: seletor de medicoes no passo 5 (2+ meios testados)
    $medBase = @($Global:Medicoes)[-1]
    $medLan = [pscustomobject]@{
        meio = 'lan'; operadora = ''; rotulo = 'Rede cabeada (LAN)'
        nao_aplicavel = $false; motivo_na = ''
        fase_local = $medBase.fase_local; rede_local_ok = $true; rede_local_download = 120
        vpn_conectou = $true; vpn_motivo = ''; vpn_download = 40
        metricas = $medBase.metricas; fase2_ok = $true
        decisao = $medBase.decisao; iperf = $medBase.iperf; ambiente = $medBase.ambiente
        avaliacoes = @(); veredito = [string] $medBase.decisao.Classificacao; quando = (Get-Date).ToString('o')
    }
    $Global:Medicoes = @(@($Global:Medicoes) + $medLan)
    Show-WizardPasso 5
    Invoke-Pump
    $boxVis = "$($w.FindName('boxMedicaoPasso5').Visibility)"
    $nOpc = @($w.FindName('cboMedicaoPasso5').ItemsSource).Count
    if ($boxVis -eq 'Visible' -and $nOpc -eq 2) { Write-Host "[5b] multi-meio: seletor de medicoes visivel com $nOpc opcoes" }
    else { Write-Host "    FALHA: seletor de medicoes do passo 5 (vis=$boxVis opc=$nOpc)"; $falhas++ }
    $idxAntes  = $Global:MedicaoPasso5Idx
    $selInicial = $w.FindName('cboMedicaoPasso5').SelectedIndex
    $novoSel   = if ($selInicial -eq 0) { 1 } else { 0 }
    $w.FindName('cboMedicaoPasso5').SelectedIndex = $novoSel
    Invoke-Pump
    if ($Global:MedicaoPasso5Idx -ne $idxAntes -and @($Global:AvaliacaoRows).Count -eq 6) {
        Write-Host "[5b] troca de medicao re-renderiza o grid (idx $idxAntes -> $($Global:MedicaoPasso5Idx))"
    } else { Write-Host "    FALHA: troca de medicao no passo 5 (idx=$($Global:MedicaoPasso5Idx) linhas=$(@($Global:AvaliacaoRows).Count))"; $falhas++ }
    $lnLan = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Latencia' } | Select-Object -First 1
    $lnLan.ClasseFinal = 'inviavel'; $lnLan.Justificativa = 'teste multi-meio'
    Invoke-Pump
    $outroSel = if ($novoSel -eq 0) { 1 } else { 0 }
    $w.FindName('cboMedicaoPasso5').SelectedIndex = $outroSel ; Invoke-Pump
    $w.FindName('cboMedicaoPasso5').SelectedIndex = $novoSel ; Invoke-Pump
    $lnLan2 = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Latencia' } | Select-Object -First 1
    if ("$($lnLan2.ClasseFinal)" -eq 'inviavel' -and "$($lnLan2.Justificativa)" -eq 'teste multi-meio') {
        Write-Host "[5b] ajuste por medicao persiste ao alternar no seletor"
    } else { Write-Host "    FALHA: ajuste da medicao nao persistiu (cf='$($lnLan2.ClasseFinal)' just='$($lnLan2.Justificativa)')"; $falhas++ }
    # limpa: volta ao meio unico e re-renderiza para o resto do teste seguir igual
    $Global:Medicoes = @(@($Global:Medicoes) | Where-Object { $_.meio -ne 'lan' })
    $Global:MedicaoPasso5Idx = -1
    Show-MedicaoNoPasso5 -Par ([pscustomobject]@{ idx = 0; med = @($Global:Medicoes)[-1] })
    Invoke-Pump
    $linha = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    $linha.ClasseFinal = 'viavel'
    Invoke-Pump

    # 5c. com justificativa -> passo 5 -> 6
    $linha.Justificativa = 'Refiz o teste pelo celular e deu 25 Mbps.'
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 6) { Write-Host "    FALHA: nao foi para o passo 6"; $falhas++ }

    # 5c-2. passo 6: seletor da conexao recomendada + tabela de medicoes
    $optsRec = @($w.FindName('cboConexaoRec').ItemsSource)
    $selRec  = [string] $w.FindName('cboConexaoRec').SelectedItem
    if ($optsRec.Count -ge 1 -and $selRec) { Write-Host "[5c] passo 6: recomendacao pre-selecionada = '$selRec' ($($optsRec.Count) opcao/oes)" }
    else { Write-Host "    FALHA: combo da conexao recomendada vazio (opts=$($optsRec.Count) sel='$selRec')"; $falhas++ }
    $nMed = @($w.FindName('dgMedicoes').ItemsSource).Count
    if ($nMed -ge 1) { Write-Host "[5c] passo 6: tabela de medicoes com $nMed linha(s)" }
    else { Write-Host "    FALHA: tabela de medicoes vazia"; $falhas++ }

    # 5c-3. passo 6 -> 7 bloqueia sem o motivo da recomendacao
    $w.FindName('txtMotivoRec').Text = ''
    Invoke-Pump
    Invoke-WizardProximo
    $ultimoLog = @($Global:LogEntries)[-1].Texto
    if ($Global:WizardStep -eq 6 -and $ultimoLog -match 'motivo da recomendacao') {
        Write-Host "[5c] passo 6 bloqueia sem o motivo da recomendacao"
    } else { Write-Host "    FALHA: passo 6 avancou sem o motivo (step=$($Global:WizardStep))"; $falhas++ }

    # 5c-4. com o motivo -> passo 7
    $w.FindName('txtMotivoRec').Text = 'Cabo nao alcanca a sala; melhor download foi pelo celular Vivo.'
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 7) { Write-Host "    FALHA: nao foi para o passo 7 com o motivo"; $falhas++ }
    else { Write-Host "[5c] passos 5->6->7 (com justificativa + motivo da recomendacao)" }

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
            @($rl.wireless_redes).Count -ge 1 -and $rl.speedtest_ok -eq $true -and $rl.internet_provedor -eq 'BARREIRAS NET' -and
            [double] $rl.internet_download_mbps -gt 800 -and "$($rl.internet_resultado_url)" -match 'speedtest') {
            Write-Host "[5d] JSON traz rede_local: host=$($rl.host) ip=$($rl.ip_local) provedor=$($rl.internet_provedor) down=$($rl.internet_download_mbps) up=$($rl.internet_upload_mbps)"
        } else { Write-Host "    FALHA: JSON sem bloco rede_local completo (host='$($rl.host)' provedor='$($rl.internet_provedor)' down='$($rl.internet_download_mbps)')"; $falhas++ }
        if ($rl.tethering_celular -eq $true -and $rl.operadora -eq 'Vivo') {
            Write-Host "[5d] rede_local traz o tethering: operadora=$($rl.operadora)"
        } else { Write-Host "    FALHA: rede_local sem tethering/operadora (t=$($rl.tethering_celular) op='$($rl.operadora)')"; $falhas++ }
        if ($doc.vpn -and $doc.vpn.impossivel -eq $false) { Write-Host "[5d] JSON traz bloco vpn (impossivel=false neste teste)" }
        else { Write-Host "    FALHA: JSON sem bloco vpn"; $falhas++ }
        $rec = $doc.conexao_recomendada
        if ($rec -and $rec.rotulo -and $rec.veredito -and $rec.motivo -match 'celular' -and @($doc.medicoes).Count -ge 1) {
            Write-Host "[5d] JSON traz conexao_recomendada='$($rec.rotulo)' veredito='$($rec.veredito)' base='$($rec.base)' + $(@($doc.medicoes).Count) medicao(oes)"
        } else { Write-Host "    FALHA: JSON sem conexao_recomendada/medicoes (rotulo='$($rec.rotulo)' motivo='$($rec.motivo)' meds=$(@($doc.medicoes).Count))"; $falhas++ }
        if ("$($doc.classificacao.final)" -eq "$($rec.veredito)") { Write-Host "[5d] decisao final do local = veredito do meio recomendado ('$($doc.classificacao.final)')" }
        else { Write-Host "    FALHA: classificacao.final ('$($doc.classificacao.final)') != veredito recomendado ('$($rec.veredito)')"; $falhas++ }
        $htmlRel = New-RelatorioHtml -Resultado $doc
        if ($htmlRel -match 'Conex&atilde;o recomendada para este local' -and $htmlRel -match 'Meios de conex&atilde;o testados') {
            Write-Host "[5d] relatorio HTML traz o bloco de conexao recomendada + tabela de meios"
        } else { Write-Host "    FALHA: relatorio HTML sem os blocos multi-meio"; $falhas++ }
    }
    $vok = [char]0x2713
    if ($Global:FeitoSalvar -and "$($w.FindName('chkFimSalvar').Text)" -eq $vok -and $w.FindName('btnTransmitirResultado').IsEnabled -and "$($w.FindName('chkFimTransmitir').Text)" -ne $vok) {
        Write-Host "[5d] checklist: Salvar=OK, Transmitir habilitado e pendente"
    } else { Write-Host "    FALHA: checklist do passo 6 (salvar=$($Global:FeitoSalvar) transmitir.en=$($w.FindName('btnTransmitirResultado').IsEnabled))"; $falhas++ }
    if (-not $w.FindName('btnFinalizarDiag').IsEnabled) { Write-Host "[5d] 'Finalizar' ainda travado (falta exportar o PDF)" }
    else { Write-Host "    FALHA: 'Finalizar' liberou so com Salvar (sem Exportar)"; $falhas++ }

    # 5d-2. exporta o relatorio pelo botao -> checklist "Exportar" fica verde
    Invoke-ExportarRelatorio
    if ($Global:FeitoExportar -and "$($w.FindName('chkFimExportar').Text)" -eq $vok -and "$($w.FindName('txtFimStatus').Text)" -match 'Relatorio salvo') {
        Write-Host "[5d] relatorio exportado ($($w.FindName('txtFimStatus').Text))"
    } else { Write-Host "    FALHA: export nao marcou o checklist (exportar=$($Global:FeitoExportar))"; $falhas++ }

    # 5d-3. "Finalizar" so habilita apos Salvar + Exportar (Transmitir pode ficar pendente)
    if ($w.FindName('btnFinalizarDiag').IsEnabled) { Write-Host "[5d] botao 'Finalizar' habilitado (salvo + exportado)" }
    else { Write-Host "    FALHA: 'Finalizar' desabilitado com resultado salvo + exportado"; $falhas++ }
    Invoke-FinalizarDiagnostico
    if ("$($w.FindName('viewHome').Visibility)" -eq 'Visible') { Write-Host "[5d] 'Finalizar' -> volta para a tela inicial" }
    else { Write-Host "    FALHA: 'Finalizar' nao voltou para a home (viewHome=$($w.FindName('viewHome').Visibility))"; $falhas++ }
    Show-WizardPasso 7   # volta ao passo 7 para os proximos testes seguirem

    # 5e. acompanhamento: guia marca o local como testado; home mostra progresso
    Show-GuiaBordo
    $grpT = @($w.FindName('lstGuiaJuntas').ItemsSource)[0]
    $locT = @($grpT.locais) | Where-Object { $_.id -eq 'ZE99-TESTE-PRINCIPAL' } | Select-Object -First 1
    if ($locT -and "$($locT.TesteStatus)" -match 'Testado' -and "$($locT.BotaoRodar)" -match 'Refazer' -and $locT.Testado -eq $true) {
        Write-Host "[5e] guia marca o local como testado: '$($locT.TesteStatus)'"
    } else {
        Write-Host "    FALHA: guia nao marcou o local como testado (status='$($locT.TesteStatus)' Testado=$($locT.Testado))"; $falhas++
    }
    # so o Principal foi testado (Contingencia ainda nao) -> cartao da ZE ainda nao fica verde
    if ($grpT.TodasTestadas -eq $false) { Write-Host "[5e] cartao da ZE ainda nao 'concluida' (falta a contingencia)" }
    else { Write-Host "    FALHA: TodasTestadas deveria ser false (so o principal foi testado)"; $falhas++ }
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

    # 8b. ambiente iperf3: campos carregam da config e "Salvar ambiente" exige PIN
    $srvCfg = "$($w.FindName('txtIperfServidorCfg').Text)"
    if ($srvCfg -and "$($w.FindName('txtIperfPortaCfg').Text)" -match '\d') {
        Write-Host "[8b] admin carrega servidor iperf3: $srvCfg`:$($w.FindName('txtIperfPortaCfg').Text)"
    } else { Write-Host "    FALHA: campos do servidor iperf3 nao carregaram (srv='$srvCfg')"; $falhas++ }
    $w.FindName('txtPinAdmin').Password = ''
    Invoke-SalvarAmbiente
    if ("$($w.FindName('lblAmbienteMsg').Text)" -match 'PIN') { Write-Host "[8b] salvar ambiente sem PIN bloqueado" }
    else { Write-Host "    FALHA: salvou ambiente sem PIN ('$($w.FindName('lblAmbienteMsg').Text)')"; $falhas++ }

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
    $Global:VpnSimulada        = $null
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
