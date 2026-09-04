# =============================================================================
#  DICON - desinstalar (remove a pasta + atalho da area de trabalho). Roda via
#  `iex (irm ...)` ou localmente. (sem #Requires/param(): tambem roda assim,
#  como o Baixar-e-Instalar.ps1.)
#
#  HOMOLOGACAO:
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Desinstalar-DICON.ps1')
#  PRODUCAO:
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/main/setup/Desinstalar-DICON.ps1')
#
#  Por padrao PROCURA sozinho as instalacoes nos locais padrao (C:\Aplic\DICON,
#  C:\Aplic\DICON-HOMOLOG, %LOCALAPPDATA%\...) e pede confirmacao (digitar SIM)
#  antes de apagar cada uma. NUNCA apaga se houver resultado salvo mas ainda
#  NAO transmitido (resultados\pendentes\*.json) -- a menos que voce force (e
#  mesmo assim faz uma copia de seguranca antes).
#
#  Opcoes (definir ANTES do comando, todas opcionais):
#      $env:DICON_DEST         = 'C:\caminho\da\instalacao'  # so essa, em vez de procurar
#      $env:DICON_FORCAR       = '1'   # nao pede confirmacao; apaga mesmo com
#                                       # pendentes (faz backup deles antes, ver abaixo)
#      $env:DICON_LIMPAR_CONTA = '1'   # tambem desconecta a Conta Google nesta
#                                       # maquina (token compartilhado entre
#                                       # producao e homologacao -- desconecta os dois)
#
#  Pra reinstalar depois, use o Baixar-e-Instalar.ps1 de sempre.
# =============================================================================
$ErrorActionPreference = 'Stop'

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function OK($t)     { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Aviso($t)  { Write-Host "  [!]    $t" -ForegroundColor Yellow }
function Erro($t)   { Write-Host "  [x]    $t" -ForegroundColor Red }

$Forcar      = $env:DICON_FORCAR -eq '1'
$LimparConta = $env:DICON_LIMPAR_CONTA -eq '1'

# --- 1. acha a(s) instalacao(oes) -------------------------------------------
Titulo 'Procurando instalacoes do DICON'
$candidatos = @()
if ($env:DICON_DEST) {
    $candidatos += $env:DICON_DEST
} else {
    foreach ($p in @(
        'C:\Aplic\DICON', 'C:\Aplic\DICON-HOMOLOG',
        (Join-Path $env:LOCALAPPDATA 'DICON'), (Join-Path $env:LOCALAPPDATA 'DICON-HOMOLOG')
    )) {
        if (Test-Path (Join-Path $p 'Iniciar-Diagnostico.bat')) { $candidatos += $p }
    }
}
if (-not $candidatos.Count) {
    Aviso 'Nenhuma instalacao do DICON encontrada nos locais padrao (C:\Aplic\DICON[-HOMOLOG] ou %LOCALAPPDATA%).'
    Aviso 'Se a instalacao estiver em outro lugar, defina $env:DICON_DEST antes de rodar de novo.'
    return
}
OK ("{0} instalacao(oes) encontrada(s): {1}" -f $candidatos.Count, ($candidatos -join ', '))

foreach ($dest in $candidatos) {
    Titulo "Instalacao: $dest"

    $canal = ''
    try { $canal = ([string] (Get-Content (Join-Path $dest 'config\canal') -Raw -ErrorAction Stop)).Trim() } catch { }
    Write-Host ("  canal: {0}" -f $(if ($canal) { $canal } else { '(desconhecido)' }))

    # --- pendentes: nunca perder diagnostico de campo nao transmitido -------
    $pastaPend = Join-Path $dest 'resultados\pendentes'
    $pend = @(Get-ChildItem -Path $pastaPend -Filter '*.json' -ErrorAction SilentlyContinue)

    if ($pend.Count -and -not $Forcar) {
        Erro ("{0} resultado(s) NAO enviado(s) em resultados\pendentes\ -- NAO vou apagar essa instalacao." -f $pend.Count)
        foreach ($p in $pend) { Write-Host "         - $($p.Name)" -ForegroundColor Red }
        Erro 'Conecte a internet e clique em "Atualizar dados" no DICON pra reenviar, e rode a desinstalacao de novo.'
        Erro 'Se tiver certeza que pode perder esses resultados, rode com $env:DICON_FORCAR = ''1'' antes do comando.'
        continue
    }

    $backup = $null
    if ($pend.Count -and $Forcar) {
        $backup = Join-Path ([IO.Path]::GetTempPath()) ('dicon-pendentes-backup-' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($p in $pend) { Copy-Item $p.FullName $backup -Force }
        Aviso ("{0} resultado(s) pendente(s) copiado(s) por seguranca antes de apagar: {1}" -f $pend.Count, $backup)
    }

    if (-not $Forcar) {
        Write-Host ''
        $r = Read-Host "  Remover TUDO em '$dest'? Digite SIM para confirmar"
        if ($r -ne 'SIM') { Aviso 'Cancelado.'; continue }
    }

    # --- atalho na area de trabalho -----------------------------------------
    try {
        $nome = if ($canal -eq 'homologacao') { 'DICON (Homologacao)' } else { 'DICON' }
        $desktop = [Environment]::GetFolderPath('DesktopDirectory')
        $lnk = Join-Path $desktop ($nome + '.lnk')
        if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue; OK "atalho removido: $lnk" }
    } catch { }

    # --- a pasta em si -------------------------------------------------------
    try {
        Remove-Item -Path $dest -Recurse -Force -ErrorAction Stop
        OK "pasta removida: $dest"
        if ($backup) { OK "resultados pendentes preservados em: $backup" }
    } catch {
        Erro "nao consegui remover $dest -- feche o DICON se estiver aberto, e tente de novo. ($_)"
    }
}

# --- conta Google (opcional; token e' compartilhado entre producao/homolog) -
if ($LimparConta) {
    Titulo 'Conta Google'
    $tok = Join-Path $env:LOCALAPPDATA 'DICON\google-refresh.dat'
    if (Test-Path $tok) {
        Remove-Item $tok -Force -ErrorAction SilentlyContinue
        OK 'token da Conta Google removido (%LOCALAPPDATA%\DICON\google-refresh.dat).'
        Aviso 'Isso desconecta producao E homologacao nesta maquina (token compartilhado).'
    } else {
        Write-Host '  (nenhum token de Conta Google salvo nesta maquina)'
    }
}

Write-Host ''
Write-Host 'Pronto. Pra reinstalar:' -ForegroundColor Green
Write-Host "  Producao:     iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/main/setup/Baixar-e-Instalar.ps1')"
Write-Host "  Homologacao:  iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Baixar-e-Instalar.ps1')"
