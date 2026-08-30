# Code-behind da janela WPF (shell com navegacao por Visibility).
# Regras de escopo ja validadas: handlers chamam FUNCOES NOMEADAS; estado em
# $Global:*; nada de .GetNewClosure() dentro do .psm1; controles resolvidos via
# $Global:JanelaPrincipal.FindName.

$Global:DiagRunState      = $null
$Global:JuntasCache       = @()
$Global:SessaoAtual       = $null
$Global:RoteiroAtual      = $null
$Global:DiagPayload       = $null   # {Ambiente;Metricas;Decisao;Local} da ultima bateria
$Global:AvaliacaoRows     = $null   # ObservableCollection[AvaliacaoRow] do painel
$Global:DecisaoRecalculada = $null
$Global:DecisaoFinalTocada = $false # tecnico mexeu no combo da decisao final?
$Global:AtualizandoDecisao = $false # guarda para nao confundir set programatico com clique
$Global:LimiarRows         = $null   # ObservableCollection[LimiarRow] da tela de admin

$Global:Views = @('viewLogin', 'viewHome', 'viewGuia', 'viewDiag', 'viewAdmin')

function Import-Xaml {
    param([string] $Caminho)
    [xml] $xml = Get-Content -Path $Caminho -Raw -Encoding UTF8
    return [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
}

function New-LogoBitmap {
    $p = Join-Path $Global:RaizApp 'assets\logo-eleicoes-2026.png'
    if (-not (Test-Path $p)) { return $null }
    try {
        $bmp = [Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource   = [Uri]::new($p)
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch {
        Write-Log "Falha ao carregar o logo: $_" -Nivel Aviso
        return $null
    }
}

function Get-PincelClassificacao {
    param([string] $Classificacao)
    switch ($Classificacao) {
        'viavel'              { [Windows.Media.Brushes]::LightGreen }
        'viavel_com_ressalva' { [Windows.Media.Brushes]::Yellow }
        default               { [Windows.Media.Brushes]::OrangeRed }
    }
}

# ------------------------------------------------------------- SHELL / NAV

function New-JanelaPrincipal {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $window = Import-Xaml (Join-Path $PSScriptRoot 'MainWindow.xaml')

    $estilos = Join-Path $PSScriptRoot 'Estilos.xaml'
    if (Test-Path $estilos) {
        $window.Resources.MergedDictionaries.Add((Import-Xaml $estilos))
    }

    $Global:JanelaPrincipal = $window
    $Global:LogEntries.Clear()   # cada abertura da janela comeca com o log limpo
    $window.FindName('lstLog').ItemsSource = $Global:LogEntries

    $logo = New-LogoBitmap
    if ($logo) {
        foreach ($n in 'imgLogoLogin', 'imgLogoHome', 'imgLogoTopo') {
            $ctrl = $window.FindName($n)
            if ($ctrl) { $ctrl.Source = $logo }
        }
    }

    # diagnostico
    $window.FindName('btnRodar').Add_Click({ Invoke-ExecucaoNaJanela })
    $window.FindName('btnAtualizar').Add_Click({ Invoke-AtualizarListaJuntas })
    $window.FindName('cboJunta').Add_SelectionChanged({ Update-ComboLocais })
    $window.FindName('btnDiagVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnSalvarResultado').Add_Click({ Invoke-SalvarResultado })
    $window.FindName('cboDecisaoFinal').Add_SelectionChanged({
            if (-not $Global:AtualizandoDecisao) { $Global:DecisaoFinalTocada = $true }
            Update-VisibilidadeJustDecisao
        })

    # login
    $window.FindName('cboTecnico').Add_SelectionChanged({ Update-VisibilidadePin })
    $window.FindName('btnEntrar').Add_Click({ Enter-Sessao })
    $window.FindName('btnBaixarLista').Add_Click({ Invoke-BaixarListaLogin })

    # home
    $window.FindName('btnMenuGuia').Add_Click({ Show-GuiaBordo })
    $window.FindName('btnMenuDiag').Add_Click({ Open-DiagnosticoLimpo })
    $window.FindName('btnMenuAdmin').Add_Click({ Show-Admin })
    $window.FindName('btnMenuAtualizar').Add_Click({ Invoke-AtualizarDados })
    $window.FindName('btnTrocarUsuario').Add_Click({ Invoke-TrocarUsuario })

    # guia / admin
    $window.FindName('btnGuiaVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnAdminVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnSalvarLimiares').Add_Click({ Invoke-SalvarLimiares })
    $window.FindName('btnRecarregarLimiares').Add_Click({ Invoke-RecarregarLimiares })
    $window.FindName('lstGuiaJuntas').AddHandler(
        [Windows.Controls.Button]::ClickEvent,
        [Windows.RoutedEventHandler] {
            param($s, $e)
            $tag = $e.OriginalSource.Tag
            if ($tag -and $tag.id) { Start-DiagnosticoDoGuia -LocalId $tag.id }
        })

    Initialize-SeletorJuntas

    # Sempre comeca no login (sem pre-selecao). A sessao gravada nao faz auto-login.
    Initialize-Login
    Show-View 'viewLogin'
    return $window
}

function Show-JanelaPrincipal {
    (New-JanelaPrincipal).ShowDialog() | Out-Null
}

function Show-View {
    param([string] $Nome)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    foreach ($v in $Global:Views) {
        $w.FindName($v).Visibility = if ($v -eq $Nome) { 'Visible' } else { 'Collapsed' }
    }
    $w.FindName('barraTopo').Visibility = if ($Nome -eq 'viewLogin') { 'Collapsed' } else { 'Visible' }
}

# ------------------------------------------------------------- LOGIN

function Initialize-Login {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $tec = @(Get-Tecnicos)
    $w.FindName('cboTecnico').ItemsSource = $tec
    $w.FindName('lblPin').Visibility = 'Collapsed'
    $w.FindName('txtPin').Visibility = 'Collapsed'
    $w.FindName('txtLoginMsg').Text = if ($tec.Count) {
        ''
    } else {
        "Nenhum tecnico no cache. Clique em 'Baixar lista' (precisa de internet)."
    }
}

function Update-VisibilidadePin {
    $w = $Global:JanelaPrincipal
    $t = $w.FindName('cboTecnico').SelectedItem
    $ehAdmin = $t -and (Test-NomeAdmin $t.nome)
    $vis = if ($ehAdmin) { 'Visible' } else { 'Collapsed' }
    $w.FindName('lblPin').Visibility = $vis
    $w.FindName('txtPin').Visibility = $vis
}

function Invoke-BaixarListaLogin {
    $w = $Global:JanelaPrincipal
    $w.FindName('txtLoginMsg').Text = 'Baixando dados...'
    try {
        $r = Sync-TudoOnline
        Initialize-Login
        $w.FindName('txtLoginMsg').Text = ("Baixado: {0} tecnicos, {1} juntas, {2} roteiros." -f $r.tecnicos, $r.juntas, $r.roteiros)
    } catch {
        $w.FindName('txtLoginMsg').Text = "Falha ao baixar: $_"
    }
}

function Enter-Sessao {
    $w = $Global:JanelaPrincipal
    $t = $w.FindName('cboTecnico').SelectedItem
    if (-not $t) { $w.FindName('txtLoginMsg').Text = 'Selecione seu nome.'; return }

    $nome  = $t.nome
    $papel = 'operador'
    if (Test-NomeAdmin $nome) {
        $pin = $w.FindName('txtPin').Password
        if (-not [string]::IsNullOrWhiteSpace($pin)) {
            if (Test-PinAdmin $pin) { $papel = 'admin' }
            else { $w.FindName('txtLoginMsg').Text = 'PIN incorreto.'; return }
        }
    }

    $sessao = Set-Sessao -TecnicoNome $nome -Papel $papel
    Enter-Home -Sessao $sessao
}

function Invoke-TrocarUsuario {
    Clear-Sessao
    $Global:SessaoAtual  = $null
    $Global:RoteiroAtual = $null
    $Global:JanelaPrincipal.FindName('txtPin').Password = ''
    Initialize-Login
    Show-View 'viewLogin'
}

# ------------------------------------------------------------- HOME

function Enter-Home {
    param($Sessao)
    $w = $Global:JanelaPrincipal
    $Global:SessaoAtual = $Sessao

    $primeiro = ($Sessao.tecnico_nome -split '\s+')[0]
    $sfx = if ($Sessao.papel -eq 'admin') { '  (administrador)' } else { '' }
    $w.FindName('txtSaudacao').Text   = "Ola, $primeiro$sfx"
    $w.FindName('txtHomeTecnico').Text = $Sessao.tecnico_nome
    $w.FindName('btnMenuAdmin').Visibility = if ($Sessao.papel -eq 'admin') { 'Visible' } else { 'Collapsed' }

    $rot = $null
    try { $rot = Get-RoteiroDoTecnico -Nome $Sessao.tecnico_nome } catch { Write-Log "Roteiro nao carregado: $_" -Nivel Aviso }
    $Global:RoteiroAtual = $rot

    $w.FindName('txtHomeRoteiro').Text = if ($rot) {
        '{0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias' -f $rot.rotulo, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias
    } else {
        'Roteiro nao encontrado no cache. Use "Atualizar dados".'
    }

    Show-View 'viewHome'
}

function Invoke-AtualizarDados {
    $w = $Global:JanelaPrincipal
    $btn = $w.FindName('btnMenuAtualizar')
    $btn.IsEnabled = $false
    $rotulo = $btn.Content
    $btn.Content = 'Atualizando...'
    try {
        $r = Sync-TudoOnline
        Write-Log ("Dados atualizados: {0} juntas, {1} tecnicos, {2} roteiros." -f $r.juntas, $r.tecnicos, $r.roteiros) -Nivel Ok
        Initialize-SeletorJuntas
        if ($Global:SessaoAtual) { Enter-Home -Sessao $Global:SessaoAtual }
    } catch {
        Write-Log "Falha ao atualizar dados: $_" -Nivel Erro
    } finally {
        $btn.Content = $rotulo
        $btn.IsEnabled = $true
    }
}

# ------------------------------------------------------------- GUIA DE BORDO

function Show-GuiaBordo {
    $w = $Global:JanelaPrincipal
    $rot = $Global:RoteiroAtual

    if (-not $rot) {
        $w.FindName('txtGuiaTitulo').Text = 'Roteiro nao disponivel'
        $w.FindName('txtGuiaSub').Text    = 'Use "Atualizar dados" com internet.'
        $w.FindName('lstTrechos').ItemsSource     = @()
        $w.FindName('lstGuiaJuntas').ItemsSource  = @()
        $w.FindName('txtGuiaSemJunta').Text       = ''
        Show-View 'viewGuia'
        return
    }

    $w.FindName('txtGuiaTitulo').Text = $rot.rotulo
    $w.FindName('txtGuiaSub').Text = ('Tecnico: {0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias    |    {5} km ({6})' -f `
            $rot.tecnico, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias, $rot.total_km, $rot.total_tempo)
    $w.FindName('lstTrechos').ItemsSource    = @($rot.trechos)
    $w.FindName('lstGuiaJuntas').ItemsSource = @($rot.juntas)

    $sem = @($rot.cidades_sem_junta)
    $w.FindName('txtGuiaSemJunta').Text = if ($sem.Count) {
        'Cidades de passagem sem Junta: ' + ($sem -join ', ')
    } else { '' }

    Show-View 'viewGuia'
}

# Abre a tela de diagnostico "limpa": sem log, sem selecao, sem resultado.
# Usada pelo menu Inicio. (Pelo guia de bordo usa-se Start-DiagnosticoDoGuia,
# que pre-seleciona o local.)
function Open-DiagnosticoLimpo {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $Global:LogEntries.Clear()
    $w.FindName('cboJunta').SelectedIndex = -1   # dispara Update-ComboLocais -> limpa cboLocal
    $w.FindName('cboLocal').ItemsSource = @()
    Clear-PainelResultado
    $w.FindName('prgProgresso').IsIndeterminate = $false
    $w.FindName('btnRodar').IsEnabled = $true

    Show-View 'viewDiag'
}

function Start-DiagnosticoDoGuia {
    param([string] $LocalId)
    $w = $Global:JanelaPrincipal

    $Global:LogEntries.Clear()
    Clear-PainelResultado

    $loc = @($Global:JuntasCache) | Where-Object { $_.id -eq $LocalId } | Select-Object -First 1
    if (-not $loc) {
        Write-Log "Local '$LocalId' nao esta no cache de juntas. Atualize os dados." -Nivel Erro
        Show-View 'viewDiag'
        return
    }

    $chave = '{0}|{1}' -f $loc.zona_eleitoral, $loc.municipio_termo
    $cboJunta = $w.FindName('cboJunta')
    $alvo = @($cboJunta.Items) | Where-Object { $_.Chave -eq $chave } | Select-Object -First 1
    if ($alvo) { $cboJunta.SelectedItem = $alvo }   # dispara Update-ComboLocais

    $cboLocal = $w.FindName('cboLocal')
    $li = @($cboLocal.Items) | Where-Object { $_.Dados.id -eq $LocalId } | Select-Object -First 1
    if ($li) { $cboLocal.SelectedItem = $li }

    Show-View 'viewDiag'
}

# ------------------------------------------------------------- ADMIN (LIMIARES)

function Show-Admin {
    Initialize-Admin
    Show-View 'viewAdmin'
}

function Initialize-Admin {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $lim = Get-LimiaresConfig
    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($info in $Global:MetricasInfo) {
        $rows.Add((New-LimiarRow -Info $info -Limiar $lim.($info.metrica)))
    }
    $Global:LimiarRows = $rows
    $w.FindName('dgLimiares').ItemsSource = $rows
    $w.FindName('txtPinAdmin').Password = ''
    $w.FindName('lblAdminMsg').Text = ''
}

function Invoke-SalvarLimiares {
    $w = $Global:JanelaPrincipal
    $msg = $w.FindName('lblAdminMsg')

    $pin = $w.FindName('txtPinAdmin').Password
    if ([string]::IsNullOrWhiteSpace($pin)) {
        $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
        $msg.Text = 'Digite o PIN do administrador para salvar.'
        return
    }

    $limiares = @{}
    foreach ($r in $Global:LimiarRows) {
        $v = 0.0; $rr = 0.0
        $okV = [double]::TryParse(($r.LimiarViavel   -replace ',', '.'), [ref] $v)
        $okR = [double]::TryParse(($r.LimiarRessalva -replace ',', '.'), [ref] $rr)
        if (-not $okV -or -not $okR -or $v -le 0 -or $rr -le 0) {
            $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
            $msg.Text = "Valores invalidos em '$($r.Rotulo)'. Use numeros maiores que zero."
            return
        }
        if ($r.Direcao -eq 'max' -and $v -gt $rr) {
            $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
            $msg.Text = "'$($r.Rotulo)': o ideal deve ser <= a ressalva."
            return
        }
        if ($r.Direcao -eq 'min' -and $v -lt $rr) {
            $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
            $msg.Text = "'$($r.Rotulo)': o ideal deve ser >= a ressalva."
            return
        }
        if ($r.Direcao -eq 'max') {
            $limiares[$r.Metrica] = @{ viavel_ate = $v; ressalva_ate = $rr }
        } else {
            $limiares[$r.Metrica] = @{ viavel_min = $v; ressalva_min = $rr }
        }
    }

    $w.FindName('btnSalvarLimiares').IsEnabled = $false
    $msg.Foreground = [Windows.Media.Brushes]::SkyBlue
    $msg.Text = 'Salvando...'
    try {
        $res = Save-Limiares -Limiares $limiares -Pin $pin
        switch ($res) {
            'ok'     { $msg.Foreground = [Windows.Media.Brushes]::LightGreen; $msg.Text = 'Limiares salvos.'; Write-Log 'Limiares salvos pelo admin.' -Nivel Ok }
            'negado' { $msg.Foreground = [Windows.Media.Brushes]::OrangeRed;  $msg.Text = 'PIN incorreto.' }
            default  { $msg.Foreground = [Windows.Media.Brushes]::OrangeRed;  $msg.Text = ($res -replace '^erro:', 'Falha: ') }
        }
    } finally {
        $w.FindName('btnSalvarLimiares').IsEnabled = $true
    }
}

function Invoke-RecarregarLimiares {
    $w = $Global:JanelaPrincipal
    $msg = $w.FindName('lblAdminMsg')
    $msg.Foreground = [Windows.Media.Brushes]::SkyBlue
    $msg.Text = 'Baixando...'
    try {
        Sync-Limiares | Out-Null
        Initialize-Admin
        $msg.Foreground = [Windows.Media.Brushes]::LightGreen
        $msg.Text = 'Limiares recarregados da planilha.'
    } catch {
        $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
        $msg.Text = "Falha ao baixar: $_"
    }
}

# ------------------------------------------------------------- DIAGNOSTICO (JUNTAS)

function Initialize-SeletorJuntas {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $locais = @(Get-Juntas)
    $Global:JuntasCache = $locais

    $cboJunta = $w.FindName('cboJunta')
    $w.FindName('cboLocal').ItemsSource = @()

    if (-not $locais.Count) {
        $cboJunta.ItemsSource = @()
        return
    }

    $juntas = $locais |
        Group-Object -Property { '{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo } |
        ForEach-Object {
            $p = $_.Group[0]
            [pscustomobject]@{
                Chave  = $_.Name
                Zona   = $p.zona_eleitoral
                Termo  = $p.municipio_termo
                Sede   = $p.municipio_sede
                Rotulo = 'ZE {0} - {1}  ({2})' -f $p.zona_eleitoral, $p.municipio_termo, $p.municipio_sede
            }
        } | Sort-Object Zona, Termo

    $cboJunta.ItemsSource = @($juntas)
    Write-Log ("Lista de Juntas carregada: {0} Juntas / {1} locais." -f @($juntas).Count, $locais.Count) -Nivel Info
}

function Update-ComboLocais {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $sel      = $w.FindName('cboJunta').SelectedItem
    $cboLocal = $w.FindName('cboLocal')
    if (-not $sel) { $cboLocal.ItemsSource = @(); return }

    $itens = @(
        $Global:JuntasCache |
            Where-Object { ('{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo) -eq $sel.Chave } |
            Sort-Object { if ($_.tipo -eq 'principal') { 0 } else { 1 } } |
            ForEach-Object {
                $rot = if ($_.tipo -eq 'principal') { 'Principal' } else { 'Contingencia' }
                [pscustomobject]@{ Rotulo = '{0}  -  {1}' -f $rot, $_.nome; Dados = $_ }
            }
    )
    $cboLocal.ItemsSource = $itens
    if ($itens.Count) { $cboLocal.SelectedIndex = 0 }
}

function Invoke-AtualizarListaJuntas {
    $w = $Global:JanelaPrincipal
    $btn = $w.FindName('btnAtualizar')
    $btn.IsEnabled = $false
    try {
        $n = Sync-Juntas
        Write-Log ("Lista atualizada: {0} locais." -f $n) -Nivel Ok
        Initialize-SeletorJuntas
    } catch {
        Write-Log "Falha ao atualizar a lista: $_" -Nivel Erro
    } finally {
        $btn.IsEnabled = $true
    }
}

function Invoke-ExecucaoNaJanela {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $selLocal = $w.FindName('cboLocal').SelectedItem
    if (-not $selLocal) {
        Write-Log 'Selecione a Junta Especial e o local antes de rodar o diagnostico.' -Nivel Aviso
        return
    }

    $w.FindName('btnRodar').IsEnabled           = $false
    $w.FindName('prgProgresso').IsIndeterminate = $true
    $Global:LogEntries.Clear()
    Clear-PainelResultado

    Start-DiagnosticoAssincrono -Local $selLocal.Dados
}

# ------------------------------------------------------------- PAINEL DE RESULTADOS

function Clear-PainelResultado {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $Global:DiagPayload        = $null
    $Global:AvaliacaoRows      = $null
    $Global:DecisaoRecalculada = $null
    $Global:DecisaoFinalTocada = $false

    $w.FindName('dgAvaliacao').ItemsSource = @()
    $Global:AtualizandoDecisao = $true
    $w.FindName('cboDecisaoFinal').SelectedItem = $null
    $Global:AtualizandoDecisao = $false
    $w.FindName('txtJustDecisao').Text  = ''
    $w.FindName('lblDecisaoRecalc').Text = ''
    $w.FindName('btnSalvarResultado').IsEnabled = $false
    Update-VisibilidadeJustDecisao
}

function Update-VisibilidadeJustDecisao {
    $w = $Global:JanelaPrincipal
    $sel = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $mostra = ($sel -and $Global:DecisaoRecalculada -and $sel -ne $Global:DecisaoRecalculada)
    $vis = if ($mostra) { 'Visible' } else { 'Collapsed' }
    $w.FindName('lblJustDecisao').Visibility = $vis
    $w.FindName('txtJustDecisao').Visibility = $vis
}

function Complete-Diagnostico {
    param($Payload, $Erro)
    $w = $Global:JanelaPrincipal

    $w.FindName('prgProgresso').IsIndeterminate = $false
    $w.FindName('btnRodar').IsEnabled = $true

    if ($Erro) {
        Write-Log "Diagnostico falhou: $Erro" -Nivel Erro
        return
    }
    Show-PainelResultado -Payload $Payload
}

function Show-PainelResultado {
    param($Payload)
    $w = $Global:JanelaPrincipal
    $Global:DiagPayload        = $Payload
    $Global:DecisaoFinalTocada = $false

    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($d in @($Payload.Decisao.Detalhes)) {
        $row = New-AvaliacaoRow -Detalhe $d
        $rows.Add($row)
        $row.add_PropertyChanged({
                param($s, $e)
                if ($e.PropertyName -eq 'ClasseFinal') { Update-DecisaoRecalculada }
            })
    }
    $Global:AvaliacaoRows = $rows
    $w.FindName('dgAvaliacao').ItemsSource = $rows

    $w.FindName('txtJustDecisao').Text = ''
    $w.FindName('btnSalvarResultado').IsEnabled = $true
    Update-DecisaoRecalculada
}

function Update-DecisaoRecalculada {
    $w = $Global:JanelaPrincipal
    if (-not $Global:AvaliacaoRows) { return }

    $classes = @($Global:AvaliacaoRows | ForEach-Object { $_.ClasseFinal })
    $recalc  = Get-ClassificacaoFinal $classes
    $Global:DecisaoRecalculada = $recalc
    $w.FindName('lblDecisaoRecalc').Text = "recalculada: $recalc"

    if (-not $Global:DecisaoFinalTocada) {
        $Global:AtualizandoDecisao = $true
        $w.FindName('cboDecisaoFinal').SelectedItem = $recalc
        $Global:AtualizandoDecisao = $false
    }
    Update-VisibilidadeJustDecisao
}

function Invoke-SalvarResultado {
    $w = $Global:JanelaPrincipal
    if (-not $Global:DiagPayload -or -not $Global:AvaliacaoRows) {
        Write-Log 'Rode o diagnostico antes de salvar.' -Nivel Aviso
        return
    }

    $avaliacoes = @()
    $faltando   = @()
    foreach ($r in $Global:AvaliacaoRows) {
        if (($r.ClasseFinal -ne $r.ClasseAutomatica) -and [string]::IsNullOrWhiteSpace($r.Justificativa)) {
            $faltando += $r.Rotulo
        }
        $avaliacoes += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
    }

    $decFinal  = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $justDec   = [string] $w.FindName('txtJustDecisao').Text
    $ajustada  = ($decFinal -and $decFinal -ne $Global:DecisaoRecalculada)
    if ($ajustada -and [string]::IsNullOrWhiteSpace($justDec)) { $faltando += 'Decisao final' }

    if ($faltando.Count) {
        Write-Log ("Justificativa obrigatoria em: {0}" -f ($faltando -join ', ')) -Nivel Erro
        return
    }

    $w.FindName('btnSalvarResultado').IsEnabled = $false
    try {
        $p = $Global:DiagPayload
        $caminho = Save-Diagnostico -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes `
            -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome)
        Write-Log "Resultado salvo: $caminho" -Nivel Ok
    } catch {
        Write-Log "Falha ao salvar: $_" -Nivel Erro
        $w.FindName('btnSalvarResultado').IsEnabled = $true
    }
}

function Start-DiagnosticoAssincrono {
    param($Local)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('RaizApp',         $Global:RaizApp)
    $rs.SessionStateProxy.SetVariable('LogEntries',      $Global:LogEntries)
    $rs.SessionStateProxy.SetVariable('JanelaPrincipal', $Global:JanelaPrincipal)
    $rs.SessionStateProxy.SetVariable('ArquivoLog',      $Global:ArquivoLog)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void] $ps.AddScript({
        param($local)
        Import-Module (Join-Path $RaizApp 'src\Conectividade.psd1') -Force
        try {
            [pscustomobject]@{ Payload = (Invoke-DiagnosticoCompleto -Local $local); Erro = $null }
        } catch {
            [pscustomobject]@{ Payload = $null; Erro = "$_" }
        }
    }).AddArgument($Local)

    $handle = $ps.BeginInvoke()

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $Global:DiagRunState = @{ PS = $ps; RS = $rs; Handle = $handle; Timer = $timer }

    $timer.Add_Tick({
        $st = $Global:DiagRunState
        if ($null -eq $st -or -not $st.Handle.IsCompleted) { return }

        $st.Timer.Stop()
        $Global:DiagRunState = $null

        $payload = $null
        $erro    = $null
        try {
            $r = $st.PS.EndInvoke($st.Handle) | Select-Object -First 1
            $payload = $r.Payload
            $erro    = $r.Erro
        } catch {
            $erro = "$_"
        } finally {
            $st.PS.Dispose()
            $st.RS.Dispose()
        }

        try {
            Complete-Diagnostico -Payload $payload -Erro $erro
        } catch {
            Write-Log "Falha ao montar o painel apos o diagnostico: $_" -Nivel Erro
        }
    })
    $timer.Start()
}
