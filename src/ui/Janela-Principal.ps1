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
$Global:NavegandoPrograma  = $false  # guarda: Show-View mexendo no rail sem disparar handler
$Global:TemaCarregado      = $false  # MahApps + Application ja inicializados neste processo?
$Global:MostrarTodasJuntas = $false  # admin: incluir Juntas fora da rota no seletor
$Global:WizardStep         = 1       # passo atual do assistente de diagnostico (1..6)
$Global:FeitoSalvar        = $false  # checklist do passo 6
$Global:FeitoTransmitir    = $false
$Global:FeitoExportar      = $false
$Global:UltimoResultadoSalvo = $null # caminho do JSON gravado no passo 6
$Global:ModoTeste          = $false  # testes: nao abrir arquivos externos

$Global:Views = @('viewLogin', 'viewHome', 'viewGuia', 'viewDiag', 'viewAdmin')

$Global:WizardPassos  = @('stepInfo', 'stepJunta', 'stepDiag', 'stepResultado', 'stepDecisao', 'stepFim')
$Global:WizardTitulos = @(
    ('Informa' + [char]0x00E7 + [char]0x00E3 + 'o do teste')
    'Junta Especial'
    ('Diagn' + [char]0x00F3 + 'stico')
    ('Resultado por m' + [char]0x00E9 + 'trica')
    ('Decis' + [char]0x00E3 + 'o final')
    ('Conclus' + [char]0x00E3 + 'o')
)

function Import-Xaml {
    param([string] $Caminho)
    [xml] $xml = Get-Content -Path $Caminho -Raw -Encoding UTF8
    return [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
}

# Carrega MahApps.Metro (lib/mahapps) e garante um System.Windows.Application,
# exigido para resolver os URIs pack://application dos dicionarios do tema.
# Idempotente: roda uma vez por processo.
function Initialize-Tema {
    if ($Global:TemaCarregado) { return }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml

    $lib = Join-Path $Global:RaizApp 'lib\mahapps'
    foreach ($d in 'ControlzEx.dll', 'Microsoft.Xaml.Behaviors.dll', 'MahApps.Metro.dll') {
        $dll = Join-Path $lib $d
        if (-not (Test-Path $dll)) { throw "Dependencia do tema nao encontrada: $dll" }
        Add-Type -Path $dll
    }

    if (-not [System.Windows.Application]::Current) {
        $app = [System.Windows.Application]::new()
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $Global:TemaCarregado = $true
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

# Pincel nos tons da identidade DICON para a barra de decisao final.
function Get-PincelVeredito {
    param([string] $Classificacao)
    $hex = switch ($Classificacao) {
        'viavel'              { '#4FC177' }
        'viavel_com_ressalva' { '#E8B93E' }
        'inviavel'            { '#E8695C' }
        default               { '#7D8698' }
    }
    $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze()
    return $b
}

function Get-PalavraVeredito {
    param([string] $Classificacao)
    switch ($Classificacao) {
        'viavel'              { 'VIAVEL' }
        'viavel_com_ressalva' { 'VIAVEL C/ RESSALVA' }
        'inviavel'            { 'INVIAVEL' }
        default               { '--' }
    }
}

# Atualiza a faixa + palavra da barra de decisao final.
function Set-BarraDecisao {
    param([string] $Classificacao)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $pincel = Get-PincelVeredito $Classificacao
    $pal = $w.FindName('txtDecisaoPalavra')
    if ($pal) { $pal.Text = Get-PalavraVeredito $Classificacao; $pal.Foreground = $pincel }
    $stripe = $w.FindName('barraDecisaoStripe')
    if ($stripe) { $stripe.Background = $pincel }
}

# Liga/desliga o indicador de progresso (anel + barra) da tela de diagnostico.
function Set-ProgressoDiag {
    param([bool] $Ativo)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $ring = $w.FindName('ringDiag')
    if ($ring) {
        $ring.IsActive   = $Ativo
        $ring.Visibility = if ($Ativo) { 'Visible' } else { 'Collapsed' }
    }
    $bar = $w.FindName('prgProgresso')
    if ($bar) { $bar.IsIndeterminate = $Ativo }
}

# ------------------------------------------------------------- SHELL / NAV

function New-JanelaPrincipal {
    Initialize-Tema

    $window = Import-Xaml (Join-Path $PSScriptRoot 'MainWindow.xaml')

    # --- Fontes da identidade: Archivo empacotada (titulos) + Segoe UI (texto) ---
    $fontDir = (Join-Path $Global:RaizApp 'assets\marca\tema\fonts') + '\'
    try {
        $baseUri = [Uri]('file:///' + ($fontDir -replace '\\', '/'))
        $window.Resources['Dicon.Display'] = [Windows.Media.FontFamily]::new($baseUri, './#Archivo')
    } catch {
        $window.Resources['Dicon.Display'] = [Windows.Media.FontFamily]::new('Segoe UI')
    }
    $window.Resources['Dicon.Body'] = [Windows.Media.FontFamily]::new('Segoe UI')

    # --- Dicionarios: MahApps (Dark.Blue) primeiro, tema DICON por ultimo ---
    foreach ($u in @(
            'pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml'
            'pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml'
            'pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Blue.xaml'
        )) {
        $rd = [System.Windows.ResourceDictionary]::new()
        $rd.Source = [Uri] $u
        $window.Resources.MergedDictionaries.Add($rd)
    }
    $window.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $PSScriptRoot 'Tema.xaml')))

    # --- Icone da janela ---
    $ico = Join-Path $Global:RaizApp 'assets\marca\dicon.ico'
    if (Test-Path $ico) {
        try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico)) } catch { }
    }

    $Global:JanelaPrincipal = $window
    $Global:LogEntries.Clear()   # cada abertura da janela comeca com o log limpo
    $window.FindName('lstLog').ItemsSource = $Global:LogEntries

    $logo = New-LogoBitmap
    if ($logo) {
        foreach ($n in 'imgLogoLogin', 'imgLogoHome') {
            $ctrl = $window.FindName($n)
            if ($ctrl) { $ctrl.Source = $logo }
        }
    }

    # diagnostico
    $window.FindName('btnRodar').Add_Click({ Invoke-ExecucaoNaJanela })
    $window.FindName('btnAtualizar').Add_Click({ Invoke-AtualizarListaJuntas })
    $window.FindName('cboJunta').Add_SelectionChanged({ Update-ComboLocais })
    $window.FindName('cboLocal').Add_SelectionChanged({ Update-DetalheLocal })
    $window.FindName('chkTodasJuntas').Add_Click({
            $Global:MostrarTodasJuntas = [bool] $Global:JanelaPrincipal.FindName('chkTodasJuntas').IsChecked
            Update-SeletorJuntas
        })
    $window.FindName('btnWizVoltar').Add_Click({ Invoke-WizardVoltar })
    $window.FindName('btnWizProximo').Add_Click({ Invoke-WizardProximo })
    $window.FindName('btnExportarPdf').Add_Click({ Invoke-ExportarRelatorio })
    $window.FindName('btnTransmitirResultado').Add_Click({ Invoke-TransmitirResultado })
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
    $window.FindName('btnReenviarPendentes').Add_Click({ Invoke-ReenvioPendentes })
    $window.FindName('btnTrocarUsuario').Add_Click({ Invoke-TrocarUsuario })

    # rail de navegacao (RadioButtons) - handlers ignoram mudanca programatica
    $window.FindName('navGuia').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-GuiaBordo } })
    $window.FindName('navDiag').Add_Checked({ if (-not $Global:NavegandoPrograma) { Open-DiagnosticoLimpo } })
    $window.FindName('navAdmin').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-Admin } })
    $window.FindName('navAtualizar').Add_Checked({ if (-not $Global:NavegandoPrograma) { Invoke-AtualizarDados } })

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
    $w.FindName('railNav').Visibility = if ($Nome -eq 'viewLogin') { 'Collapsed' } else { 'Visible' }

    # sincroniza o item ativo do rail sem disparar os handlers de navegacao
    $map = @{ viewGuia = 'navGuia'; viewDiag = 'navDiag'; viewAdmin = 'navAdmin' }
    $Global:NavegandoPrograma = $true
    foreach ($nn in 'navGuia', 'navDiag', 'navAdmin', 'navAtualizar') {
        $rb = $w.FindName($nn)
        if ($rb) { $rb.IsChecked = ($map[$Nome] -eq $nn) }
    }
    $Global:NavegandoPrograma = $false
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
    $w.FindName('txtSaudacao').Text     = "Ola, $primeiro$sfx"
    $w.FindName('txtRailTecnico').Text  = $Sessao.tecnico_nome
    $w.FindName('txtHomeTecnico').Text  = "Ola, $primeiro"

    $visAdmin = if ($Sessao.papel -eq 'admin') { 'Visible' } else { 'Collapsed' }
    $w.FindName('btnMenuAdmin').Visibility = $visAdmin
    $w.FindName('navAdmin').Visibility     = $visAdmin

    # seletor de Juntas volta ao padrao "so da rota" a cada troca de usuario
    $Global:MostrarTodasJuntas = $false
    $chkTodas = $w.FindName('chkTodasJuntas')
    $chkTodas.IsChecked  = $false
    $chkTodas.Visibility = $visAdmin

    $rot = $null
    try { $rot = Get-RoteiroDoTecnico -Nome $Sessao.tecnico_nome } catch { Write-Log "Roteiro nao carregado: $_" -Nivel Aviso }
    $Global:RoteiroAtual = $rot
    Update-SeletorJuntas

    $w.FindName('txtHomeRoteiro').Text = if ($rot) {
        '{0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias' -f $rot.rotulo, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias
    } else {
        'Roteiro nao encontrado no cache. Use "Atualizar dados".'
    }

    if ($rot) {
        $prog = Get-ProgressoRoteiro -Roteiro $rot -TecnicoNome $Sessao.tecnico_nome
        $w.FindName('txtTileDias').Text   = [string] $rot.dias
        $w.FindName('txtTileLocais').Text = [string] $prog.Total
        $w.FindName('txtTileKm').Text     = [string] $rot.total_km

        $w.FindName('txtProgressoRoteiro').Text = '{0} de {1} locais testados' -f $prog.Testados, $prog.Total
        $pb = $w.FindName('prgProgressoRoteiro')
        $pb.Maximum = [math]::Max($prog.Total, 1)
        $pb.Value   = $prog.Testados
        $w.FindName('painelProgressoRoteiro').Visibility = 'Visible'
    } else {
        foreach ($t in 'txtTileDias', 'txtTileLocais', 'txtTileKm') { $w.FindName($t).Text = '--' }
        $w.FindName('painelProgressoRoteiro').Visibility = 'Collapsed'
    }

    Update-AvisoPendentes
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

        $cfgEnvio = $null
        try { $cfgEnvio = Get-Config 'envio' } catch { }
        if (-not $cfgEnvio -or $cfgEnvio.reenvio_ao_atualizar -ne $false) {
            Send-ResultadosPendentes -Endpoint $cfgEnvio.endpoint_apps_script | Out-Null
        }

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

    # marca cada local com o status do ultimo diagnostico feito pelo tecnico
    $feitos = Get-DiagnosticosRealizados -TecnicoNome $Global:SessaoAtual.tecnico_nome
    $cinza  = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
    $cinza.Freeze()
    foreach ($grupo in @($rot.juntas)) {
        foreach ($loc in @($grupo.locais)) {
            $d = $feitos[[string] $loc.id]
            if ($d) {
                $ver = switch ($d.ClassificacaoFinal) {
                    'viavel'              { 'vi' + [char]0x00E1 + 'vel' }
                    'viavel_com_ressalva' { 'vi' + [char]0x00E1 + 'vel c/ ressalva' }
                    'inviavel'            { 'invi' + [char]0x00E1 + 'vel' }
                    default               { [string] $d.ClassificacaoFinal }
                }
                $sfx = if ($d.Enviado) { '' } else { '  (nao enviado)' }
                $txt = 'Testado {0:dd/MM HH:mm}  -  {1}{2}' -f $d.Quando, $ver, $sfx
                $cor = Get-PincelVeredito $d.ClassificacaoFinal
                $bot = 'Refazer teste'
            } else {
                $txt = 'N' + [char]0x00E3 + 'o testado'
                $cor = $cinza
                $bot = 'Rodar diagn' + [char]0x00F3 + 'stico'
            }
            $loc | Add-Member -NotePropertyName TesteStatus -NotePropertyValue $txt -Force
            $loc | Add-Member -NotePropertyName TesteCor    -NotePropertyValue $cor -Force
            $loc | Add-Member -NotePropertyName BotaoRodar  -NotePropertyValue $bot -Force
        }
    }
    $w.FindName('lstGuiaJuntas').ItemsSource = @($rot.juntas)

    $sem = @($rot.cidades_sem_junta)
    $w.FindName('txtGuiaSemJunta').Text = if ($sem.Count) {
        'Cidades de passagem sem Junta: ' + ($sem -join ', ')
    } else { '' }

    Show-View 'viewGuia'
}

# ------------------------------------------------------------- ASSISTENTE (WIZARD)

function Show-WizardPasso {
    param([int] $N)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    if ($N -lt 1) { $N = 1 }
    if ($N -gt 6) { $N = 6 }
    $Global:WizardStep = $N

    for ($i = 0; $i -lt 6; $i++) {
        $vis = if ($i -eq ($N - 1)) { 'Visible' } else { 'Collapsed' }
        $w.FindName($Global:WizardPassos[$i]).Visibility = $vis
    }
    $w.FindName('txtWizTitulo').Text = $Global:WizardTitulos[$N - 1]
    $w.FindName('txtWizPasso').Text  = 'Passo {0} de 6' -f $N
    $w.FindName('prgWizard').Value   = $N

    $w.FindName('btnWizVoltar').IsEnabled = ($N -gt 1)
    $prox = $w.FindName('btnWizProximo')
    $prox.Visibility = if ($N -lt 6) { 'Visible' } else { 'Collapsed' }
    $prox.Content    = if ($N -eq 5) { 'Concluir' } else { 'Pr' + [char]0x00F3 + 'ximo' }

    switch ($N) {
        2 { Update-DetalheLocal }
        3 {
            $sel = $w.FindName('cboLocal').SelectedItem
            $w.FindName('txtDiagLocal').Text = if ($sel) { 'Local: ' + $sel.Rotulo } else { 'Volte e selecione o local.' }
            $w.FindName('btnRodar').IsEnabled = [bool] $sel
        }
        5 { Update-DecisaoRecalculada }
        6 { Update-ResumoFim }
    }
}

function Invoke-WizardVoltar {
    if ($Global:WizardStep -gt 1) { Show-WizardPasso ($Global:WizardStep - 1) }
}

function Invoke-WizardProximo {
    $w = $Global:JanelaPrincipal
    switch ($Global:WizardStep) {
        1 { Show-WizardPasso 2 }
        2 {
            if (-not $w.FindName('cboLocal').SelectedItem) {
                Write-Log 'Selecione a Junta Especial e o Local para continuar.' -Nivel Aviso
                return
            }
            Show-WizardPasso 3
        }
        3 {
            if (-not $Global:DiagPayload) {
                Write-Log 'Rode o diagnostico antes de avancar.' -Nivel Aviso
                return
            }
            Show-WizardPasso 4
        }
        4 {
            $falta = Get-JustificativasFaltando -MetricasApenas
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            Show-WizardPasso 5
        }
        5 {
            $falta = Get-JustificativasFaltando
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            Show-WizardPasso 6
        }
    }
}

# Lista de itens sem justificativa obrigatoria (metricas ajustadas + decisao).
function Get-JustificativasFaltando {
    param([switch] $MetricasApenas)
    $w = $Global:JanelaPrincipal
    $falta = @()
    foreach ($r in @($Global:AvaliacaoRows)) {
        if (($r.ClasseFinal -ne $r.ClasseAutomatica) -and [string]::IsNullOrWhiteSpace($r.Justificativa)) {
            $falta += $r.Rotulo
        }
    }
    if (-not $MetricasApenas) {
        $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
        $justDec  = [string] $w.FindName('txtJustDecisao').Text
        if ($decFinal -and $decFinal -ne $Global:DecisaoRecalculada -and [string]::IsNullOrWhiteSpace($justDec)) {
            $falta += 'Decisao final'
        }
    }
    return @($falta)
}

# Linha "<Rotulo>: <Valor>" do cartao de detalhe; oculta se o valor for vazio.
function Set-LinhaDetalhe {
    param($Ctrl, [string] $Rotulo, [string] $Valor)
    if (-not $Ctrl) { return }
    if ([string]::IsNullOrWhiteSpace($Valor)) { $Ctrl.Visibility = 'Collapsed'; return }
    $Ctrl.Text       = '{0}: {1}' -f $Rotulo, $Valor
    $Ctrl.Visibility = 'Visible'
}

# Preenche o cartao "Local selecionado" no passo 2.
function Update-DetalheLocal {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $sel  = $w.FindName('cboLocal').SelectedItem
    $card = $w.FindName('cardDetalheLocal')
    if (-not $card) { return }
    if (-not $sel) { $card.Visibility = 'Collapsed'; return }

    $d = $sel.Dados
    $w.FindName('txtDetTipo').Text     = if ($d.tipo -eq 'principal') { 'LOCAL PRINCIPAL' } else { 'LOCAL DE CONTINGENCIA' }
    $w.FindName('txtDetNome').Text     = [string] $d.nome
    $w.FindName('txtDetZE').Text       = Format-RotuloJunta $d.zona_eleitoral $d.municipio_termo $d.municipio_sede
    $w.FindName('txtDetEndereco').Text = [string] $d.endereco
    $w.FindName('txtDetInternet').Text = 'Internet: ' + [string] $d.tipo_internet

    $resp = Get-CampoLocal $d 'responsavel'
    $func = Get-CampoLocal $d 'funcao'
    if ($func) { $resp = '{0} ({1})' -f $resp, $func }
    Set-LinhaDetalhe $w.FindName('txtDetUC')          'Unidade consumidora'  (Get-CampoLocal $d 'unidade_consumidora')
    Set-LinhaDetalhe $w.FindName('txtDetResponsavel') 'Responsavel'          $resp
    Set-LinhaDetalhe $w.FindName('txtDetTelefone')    'Telefone/WhatsApp'    (Get-CampoLocal $d 'telefone')

    $feitos = Get-DiagnosticosRealizados -TecnicoNome $Global:SessaoAtual.tecnico_nome
    $t   = $feitos[[string] $d.id]
    $lbl = $w.FindName('txtDetTestado')
    if ($t) {
        $lbl.Text       = 'Ja diagnosticado em {0:dd/MM/yyyy HH:mm} - {1}' -f $t.Quando, $t.ClassificacaoFinal
        $lbl.Foreground = Get-PincelVeredito $t.ClassificacaoFinal
    } else {
        $cinza = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
        $cinza.Freeze()
        $lbl.Text       = 'Ainda nao diagnosticado neste roteiro.'
        $lbl.Foreground = $cinza
    }
    $card.Visibility = 'Visible'
}

# Atualiza os check-marks do passo 6 (verde = feito, vermelho = pendente).
function Update-ChecklistFim {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $verde    = Get-PincelVeredito 'viavel'
    $vermelho = Get-PincelVeredito 'inviavel'
    $itens = @(
        @{ n = 'chkFimSalvar';    ok = $Global:FeitoSalvar }
        @{ n = 'chkFimTransmitir'; ok = $Global:FeitoTransmitir }
        @{ n = 'chkFimExportar';   ok = $Global:FeitoExportar }
    )
    foreach ($it in $itens) {
        $t = $w.FindName($it.n)
        if (-not $t) { continue }
        $t.Text       = if ($it.ok) { [char]0x2713 } else { [char]0x2717 }
        $t.Foreground = if ($it.ok) { $verde } else { $vermelho }
    }
}

# Preenche o passo 6 (conclusao).
function Update-ResumoFim {
    $w = $Global:JanelaPrincipal
    $p = $Global:DiagPayload
    if (-not $p) { return }
    $dec = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $w.FindName('txtFimLocal').Text = 'ZE {0} - {1} / {2} ({3})' -f `
        $p.Local.zona_eleitoral, $p.Local.municipio_termo, $p.Local.nome, $p.Local.tipo
    $ver = $w.FindName('txtFimVeredito')
    $ver.Text       = Get-PalavraVeredito $dec
    $ver.Foreground = Get-PincelVeredito $dec
    $w.FindName('btnSalvarResultado').IsEnabled     = $true
    $w.FindName('btnExportarPdf').IsEnabled         = $true
    $w.FindName('btnTransmitirResultado').IsEnabled = $Global:FeitoSalvar
    Update-ChecklistFim
}

function Invoke-TransmitirResultado {
    $w = $Global:JanelaPrincipal
    if (-not $Global:UltimoResultadoSalvo -or -not (Test-Path $Global:UltimoResultadoSalvo)) {
        Write-Log 'Salve o resultado antes de transmitir.' -Nivel Aviso
        $st = $w.FindName('txtFimStatus'); if ($st) { $st.Text = 'Salve o resultado antes de transmitir.' }
        return
    }
    $btn = $w.FindName('btnTransmitirResultado'); $btn.IsEnabled = $false
    $st  = $w.FindName('txtFimStatus'); $st.Text = 'Transmitindo...'
    try {
        $cfg = $null
        try { $cfg = Get-Config 'envio' } catch { }
        $ok = Send-Resultado -Caminho $Global:UltimoResultadoSalvo -Endpoint $cfg.endpoint_apps_script `
            -Retentativas ($cfg.retentativas) -IntervaloS ($cfg.intervalo_retentativa_s)
        if ($ok) {
            $Global:FeitoTransmitir = $true
            $st.Text = 'Resultado transmitido ao painel.'
        } else {
            $st.Text = 'Nao foi possivel transmitir agora. O resultado fica pendente e vai no proximo "Atualizar dados".'
            $btn.IsEnabled = $true
        }
    } catch {
        Write-Log "Falha ao transmitir: $_" -Nivel Erro
        $st.Text = "Falha ao transmitir: $_"
        $btn.IsEnabled = $true
    }
    Update-ChecklistFim
    Update-AvisoPendentes
}

function Invoke-ExportarRelatorio {
    $w = $Global:JanelaPrincipal
    if (-not $Global:DiagPayload -or -not $Global:AvaliacaoRows) {
        Write-Log 'Rode o diagnostico antes de exportar o relatorio.' -Nivel Aviso
        return
    }
    $btn = $w.FindName('btnExportarPdf'); $btn.IsEnabled = $false
    $st  = $w.FindName('txtFimStatus');  $st.Text = 'Gerando relatorio...'
    try {
        $avaliacoes = @()
        foreach ($r in @($Global:AvaliacaoRows)) {
            $avaliacoes += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
        }
        $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
        $justDec  = [string] $w.FindName('txtJustDecisao').Text
        $p = $Global:DiagPayload
        $res = New-ResultadoJson -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome)
        $out = Export-RelatorioPdf -Resultado $res
        $Global:FeitoExportar = $true
        $st.Text = "Relatorio salvo: $out"
        if (-not $Global:ModoTeste) { try { Start-Process -FilePath $out } catch { } }
    } catch {
        $st.Text = "Falha ao exportar: $_"
        Write-Log "Falha ao exportar relatorio: $_" -Nivel Erro
    } finally {
        $btn.IsEnabled = $true
    }
    Update-ChecklistFim
}

# Abre o assistente de diagnostico do zero (menu Inicio / rail).
function Open-DiagnosticoLimpo {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $Global:LogEntries.Clear()
    $w.FindName('cboJunta').SelectedIndex = -1   # dispara Update-ComboLocais -> limpa cboLocal
    $w.FindName('cboLocal').ItemsSource = @()
    Clear-PainelResultado
    Set-ProgressoDiag $false
    Show-WizardPasso 1
    Show-View 'viewDiag'
}

# Abre o assistente pelo atalho do guia de bordo: comeca no passo 1, mas ja
# pre-seleciona a Junta/Local que o tecnico clicou.
function Start-DiagnosticoDoGuia {
    param([string] $LocalId)
    $w = $Global:JanelaPrincipal

    $Global:LogEntries.Clear()
    Clear-PainelResultado
    Set-ProgressoDiag $false

    $loc = @($Global:JuntasCache) | Where-Object { $_.id -eq $LocalId } | Select-Object -First 1
    if ($loc) {
        $chave = '{0}|{1}' -f $loc.zona_eleitoral, $loc.municipio_termo
        $cboJunta = $w.FindName('cboJunta')
        $alvo = @($cboJunta.Items) | Where-Object { $_.Chave -eq $chave } | Select-Object -First 1
        if ($alvo) { $cboJunta.SelectedItem = $alvo }   # dispara Update-ComboLocais

        $cboLocal = $w.FindName('cboLocal')
        $li = @($cboLocal.Items) | Where-Object { $_.Dados.id -eq $LocalId } | Select-Object -First 1
        if ($li) { $cboLocal.SelectedItem = $li }
    } else {
        Write-Log "Local '$LocalId' nao esta no cache de juntas. Atualize os dados." -Nivel Aviso
    }

    Show-WizardPasso 1
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

    $Global:JuntasCache = @(Get-Juntas)
    $w.FindName('cboLocal').ItemsSource = @()
    Update-SeletorJuntas
}

# Rotulo da Junta no formato "<Municipio termo> - ZE-XXX <Municipio sede>".
function Format-ZonaNum {
    param($Zona)
    $n = 0
    if ([int]::TryParse([string] $Zona, [ref] $n)) { return '{0:D3}' -f $n }
    return [string] $Zona
}
function Format-MunicipioSede {
    param([string] $Sede)
    if ([string]::IsNullOrWhiteSpace($Sede)) { return '' }
    $conect = 'de', 'da', 'do', 'das', 'dos', 'e'
    $ti = (Get-Culture).TextInfo
    (($Sede.ToLower() -split '\s+') | ForEach-Object {
        if ($_ -in $conect) { $_ } else { $ti.ToTitleCase($_) }
    }) -join ' '
}
function Format-RotuloJunta {
    param($Zona, [string] $Termo, [string] $Sede)
    '{0} - ZE-{1} {2}' -f $Termo, (Format-ZonaNum $Zona), (Format-MunicipioSede $Sede)
}

# Popula o combo "Junta Especial": so as Juntas da rota do tecnico logado, a
# menos que o admin tenha marcado "incluir fora da rota" (ou nao haja roteiro).
function Update-SeletorJuntas {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $cboJunta = $w.FindName('cboJunta')
    $locais = @($Global:JuntasCache)
    if (-not $locais.Count) { $cboJunta.ItemsSource = @(); return }

    $rot = $Global:RoteiroAtual
    $chavesRota = @()
    if ($rot) {
        $chavesRota = @($rot.juntas | ForEach-Object { '{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo })
    }
    $filtrar = ($chavesRota.Count -gt 0) -and (-not $Global:MostrarTodasJuntas)

    $juntas = $locais |
        Group-Object -Property { '{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo } |
        ForEach-Object {
            $p = $_.Group[0]
            [pscustomobject]@{
                Chave  = $_.Name
                Zona   = $p.zona_eleitoral
                Termo  = $p.municipio_termo
                Sede   = $p.municipio_sede
                NaRota = ($_.Name -in $chavesRota)
                Rotulo = Format-RotuloJunta $p.zona_eleitoral $p.municipio_termo $p.municipio_sede
            }
        }

    if ($filtrar) { $juntas = $juntas | Where-Object { $_.NaRota } }
    $juntas = @($juntas | Sort-Object @{ Expression = { -not $_.NaRota } }, Zona, Termo)

    $cboJunta.ItemsSource = $juntas
    $modo = if ($filtrar) { 'rota do tecnico' } elseif ($chavesRota.Count) { 'todas (admin)' } else { 'todas (sem roteiro)' }
    Write-Log ("Seletor de Juntas: {0} Junta(s) - {1}." -f $juntas.Count, $modo) -Nivel Info
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

    $w.FindName('btnRodar').IsEnabled = $false
    Set-ProgressoDiag $true
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
    $w.FindName('btnExportarPdf').IsEnabled = $false
    $w.FindName('btnTransmitirResultado').IsEnabled = $false
    $w.FindName('txtFimStatus').Text = ''
    $w.FindName('cardDetalheLocal').Visibility = 'Collapsed'
    $Global:FeitoSalvar     = $false
    $Global:FeitoTransmitir = $false
    $Global:FeitoExportar   = $false
    $Global:UltimoResultadoSalvo = $null
    Update-ChecklistFim
    Update-VisibilidadeJustDecisao
}

function Update-VisibilidadeJustDecisao {
    $w = $Global:JanelaPrincipal
    $sel = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $mostra = ($sel -and $Global:DecisaoRecalculada -and $sel -ne $Global:DecisaoRecalculada)
    $vis = if ($mostra) { 'Visible' } else { 'Collapsed' }
    $w.FindName('lblJustDecisao').Visibility = $vis
    $w.FindName('txtJustDecisao').Visibility = $vis
    Set-BarraDecisao $sel
}

function Complete-Diagnostico {
    param($Payload, $Erro)
    $w = $Global:JanelaPrincipal

    Set-ProgressoDiag $false
    $w.FindName('btnRodar').IsEnabled = $true

    if ($Erro) {
        Write-Log "Diagnostico falhou: $Erro" -Nivel Erro
        return
    }
    Show-PainelResultado -Payload $Payload
    if ($Global:WizardStep -eq 3) { Show-WizardPasso 4 }
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

    $falta = Get-JustificativasFaltando
    if ($falta.Count) {
        Write-Log ("Justificativa obrigatoria em: {0}" -f ($falta -join ', ')) -Nivel Erro
        $st = $w.FindName('txtFimStatus'); if ($st) { $st.Text = 'Falta justificar: ' + ($falta -join ', ') }
        return
    }

    $avaliacoes = @()
    foreach ($r in $Global:AvaliacaoRows) {
        $avaliacoes += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
    }
    $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $justDec  = [string] $w.FindName('txtJustDecisao').Text

    $w.FindName('btnSalvarResultado').IsEnabled = $false
    try {
        $p = $Global:DiagPayload
        $caminho = Save-Diagnostico -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes `
            -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome)
        Write-Log "Resultado salvo: $caminho" -Nivel Ok
        $Global:FeitoSalvar          = $true
        $Global:UltimoResultadoSalvo = $caminho
        $w.FindName('btnTransmitirResultado').IsEnabled = $true
        $st = $w.FindName('txtFimStatus'); if ($st) { $st.Text = 'Resultado salvo neste notebook. Use "Transmitir" para enviar agora.' }
    } catch {
        Write-Log "Falha ao salvar: $_" -Nivel Erro
        $w.FindName('btnSalvarResultado').IsEnabled = $true
    }
    Update-ChecklistFim
    Update-AvisoPendentes
}

# ------------------------------------------------------------- ENVIO PENDENTES

# Mostra/oculta o aviso "N resultado(s) aguardando envio" na tela inicial.
function Update-AvisoPendentes {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $btn = $w.FindName('btnReenviarPendentes')
    if (-not $btn) { return }

    $n = @(Get-ChildItem (Join-Path $Global:RaizApp 'resultados\pendentes') -Filter '*.json' -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) {
        $btn.Content = if ($n -eq 1) {
            '1 resultado aguardando envio  -  Reenviar'
        } else {
            '{0} resultados aguardando envio  -  Reenviar' -f $n
        }
        $btn.Visibility = 'Visible'
    } else {
        $btn.Visibility = 'Collapsed'
    }
}

function Invoke-ReenvioPendentes {
    $w = $Global:JanelaPrincipal
    $btn = $w.FindName('btnReenviarPendentes')
    if ($btn) { $btn.IsEnabled = $false; $btn.Content = 'Reenviando...' }
    try {
        $cfg = $null
        try { $cfg = Get-Config 'envio' } catch { }
        Send-ResultadosPendentes -Endpoint $cfg.endpoint_apps_script | Out-Null
    } catch {
        Write-Log "Falha ao reenviar pendentes: $_" -Nivel Erro
    } finally {
        if ($btn) { $btn.IsEnabled = $true }
        Update-AvisoPendentes
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
