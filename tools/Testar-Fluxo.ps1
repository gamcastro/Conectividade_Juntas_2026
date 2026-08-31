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

# ---- preserva caches reais e injeta fixtures -----------------------------
$dataDir = Join-Path $Global:RaizApp 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

$arquivos = 'juntas.json', 'tecnicos.json', 'roteiros.json', 'sessao.json', 'limiares.json'
$backups  = @{}
foreach ($a in $arquivos) {
    $p = Join-Path $dataDir $a
    if (Test-Path $p) { $b = "$p.bak-teste"; Move-Item $p $b -Force; $backups[$p] = $b }
}

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

    # 4c. passo 2 -> 3
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 3) { Write-Host "[4c] FALHA: nao foi para o passo 3"; $falhas++ }

    # 4d. passo 3 -> 4 bloqueia antes de rodar o diagnostico
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 3) { Write-Host "[4d] FALHA: avancou sem rodar o diagnostico"; $falhas++ }
    else { Write-Host "[4d] passo 3 bloqueia antes de rodar" }

    # 5. roda a bateria -> auto-avanca para o passo 4
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
    if ($Global:WizardStep -ne 4) { Write-Host "    FALHA: nao auto-avancou para o passo 4"; $falhas++ }
    if ($nLinhas -ne 6) { Write-Host "    FALHA: painel deveria ter 6 linhas"; $falhas++ }
    if ($decIni -notin @('viavel', 'viavel_com_ressalva', 'inviavel')) { Write-Host "    FALHA: decisao nao classificou"; $falhas++ }

    # 5b. override de metrica + passo 4 -> 5 bloqueia sem justificativa
    $linha = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    $linha.ClasseFinal = 'viavel'
    Invoke-Pump
    Invoke-WizardProximo
    $ultimoLog = @($Global:LogEntries)[-1].Texto
    if ($Global:WizardStep -eq 4 -and $ultimoLog -match 'Justificativa obrigatoria') {
        Write-Host "[5b] passo 4 bloqueia override sem justificativa"
    } else { Write-Host "    FALHA: passo 4 avancou sem justificativa (step=$($Global:WizardStep))"; $falhas++ }

    # 5c. com justificativa -> passos 4 -> 5 -> 6
    $linha.Justificativa = 'Refiz o teste pelo celular e deu 25 Mbps.'
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 5) { Write-Host "    FALHA: nao foi para o passo 5"; $falhas++ }
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 6) { Write-Host "    FALHA: nao foi para o passo 6"; $falhas++ }
    else { Write-Host "[5c] passos 4->5->6 com justificativa" }

    # 5d. passo 6: salva o resultado
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
    }

    # 5d-2. exporta o relatorio (PDF via navegador; HTML se nao houver)
    $pp  = $Global:DiagPayload
    $res = New-ResultadoJson -Ambiente $pp.Ambiente -Metricas $pp.Metricas -Decisao $pp.Decisao -Local $pp.Local `
        -Avaliacoes @(@{ metrica = 'banda_download_mbps'; classe_final = 'viavel'; justificativa = 'teste' }) `
        -ClassificacaoFinal @{ final = ([string] $w.FindName('cboDecisaoFinal').SelectedItem); justificativa = '' } `
        -TecnicoNome 'TECNICO HEADLESS'
    $rel = Export-RelatorioPdf -Resultado $res
    if ($rel -and (Test-Path $rel)) {
        Write-Host "[5d] relatorio gerado: $(Split-Path $rel -Leaf)"
        Remove-Item $rel -Force -EA SilentlyContinue
        Remove-Item ([IO.Path]::ChangeExtension($rel, '.html')) -Force -EA SilentlyContinue
    } else { Write-Host "    FALHA: relatorio nao gerado"; $falhas++ }

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
    if ($selLimpo -or $Global:LogEntries.Count -ne 0 -or -not $painelLimpo -or $Global:WizardStep -ne 1) {
        Write-Host "[6] FALHA: nao abriu limpo (sel=$([bool]$selLimpo) log=$($Global:LogEntries.Count) painel=$($w.FindName('dgAvaliacao').Items.Count) payload=$($null -ne $Global:DiagPayload) step=$($Global:WizardStep))"
        $falhas++
    } else { Write-Host "[6] Assistente pelo menu abre limpo no passo 1" }

    # 7. trocar usuario
    Invoke-TrocarUsuario
    if ($w.FindName('viewLogin').Visibility -ne 'Visible') { Write-Host "[7] FALHA: 'trocar usuario' nao voltou ao login"; $falhas++ }
    else { Write-Host "[7] Trocar usuario -> login OK" }

    # 8. admin: tela de limiares (sem POST real)
    Set-Sessao -TecnicoNome $Global:AdminNome -Papel 'admin' | Out-Null
    Enter-Home -Sessao (Get-Sessao)
    if ($w.FindName('btnMenuAdmin').Visibility -ne 'Visible') { Write-Host "[8] FALHA: botao Administracao nao aparece para admin"; $falhas++ }
    if ($w.FindName('chkTodasJuntas').Visibility -ne 'Visible') { Write-Host "    FALHA: admin sem opcao 'incluir Juntas fora da rota'"; $falhas++ }
    else { Write-Host "[8] admin ve a opcao de incluir Juntas fora da rota" }
    Show-Admin
    $nLim = $w.FindName('dgLimiares').Items.Count
    Write-Host "[8] Admin: $nLim linha(s) de limiar"
    if ($nLim -ne 6) { Write-Host "    FALHA: deveria ter 6 metricas"; $falhas++ }
    $w.FindName('txtPinAdmin').Password = ''
    Invoke-SalvarLimiares
    if ($w.FindName('lblAdminMsg').Text -notmatch 'PIN') { Write-Host "    FALHA: salvou limiares sem PIN"; $falhas++ }
    else { Write-Host "[8] salvar limiares sem PIN bloqueado" }
}
finally {
    foreach ($a in $arquivos) { $p = Join-Path $dataDir $a; if (Test-Path $p) { Remove-Item $p -Force } }
    foreach ($kv in $backups.GetEnumerator()) { Move-Item $kv.Value $kv.Key -Force }
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
