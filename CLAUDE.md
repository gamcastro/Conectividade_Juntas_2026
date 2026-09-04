# DICON — Diagnóstico de Conectividade

> **DICON** = **Di**agnóstico de **Con**ectividade. (Repositório: `Conectividade_Juntas_2026`.)

## Contexto
Ferramenta de diagnóstico de conectividade e viabilidade de infraestrutura de TIC
para as Juntas Eleitorais Especiais 2026 do TRE-MA. Os locais das juntas ficam
espalhados pelo interior do Maranhão, usam internet local (sem link dedicado) e
se conectam à rede da Justiça Eleitoral via VPN. Técnicos de vistoria levam um
notebook Windows 11 para rodar os testes em campo, no momento da visita ao local.

O objetivo é permitir que o técnico, sozinho, rode uma bateria de testes local e
receba na hora uma classificação objetiva (viável / viável com ressalva /
inviável) sobre usar aquele local para a Junta Especial — substituindo o
processo manual atual (ping + download cronometrado à mão).

## Projeto irmão
Este projeto é companheiro do `Vistoria_Juntas_2026` (Google Sheets + Apps
Script), que já cobre estrutura, elétrica e segurança do checklist de vistoria.
A ideia é que este módulo de conectividade alimente o mesmo backend (Apps
Script), em vez de criar um BI/dashboard separado.

## Stack e componentes
- **PowerShell** como orquestrador principal
- **GUI WPF + MahApps.Metro** (`MetroWindow`, tema DICON) — DLLs versionadas em
  `lib/mahapps/`; tema em `src/ui/Tema.xaml`; fonte Archivo em
  `assets/marca/tema/fonts/`. Aplicada só na branch `homologacao` por ora.
- **iperf3** (client Windows em `bin/iperf3/` — **versionado** no repo:
  `iperf3.exe` BSD-3 + `cygwin1.dll` LGPLv3 + `cygcrypto-3.dll` + `cygz.dll`,
  licenças em `bin/iperf3/LICENSES.md`; `Atualizar-DICON.ps1` espelha essa pasta)
  — banda real pela VPN contra servidor iperf3 num Ubuntu no CPD (endereço/porta/duração
  editáveis na tela de **Administração** → `Save-ConfigAmbiente` grava o bloco
  `iperf3` em `config/ambiente.json` local, PIN do admin). `Test-BandaVpn`
  (`src/testes/Test-Banda.ps1`) roda download (`-R`) e upload (`-f m`), lê a
  saída linha a linha e transmite cada intervalo (`Write-EventoIperf` →
  `Update-IperfGauge`) para um **velocímetro** no passo 4, igual ao do Speedtest.
- **Ping nativo do Windows** — latência, jitter e perda
- **Fase 1 — rede local (ANTES da VPN do TRE)** (`src/core/RedeLocal.ps1`,
  `Invoke-FaseLocal`): inventário da placa cabeada (LAN conectada? **IP local**,
  máscara, gateway, DNS, MAC, velocidade — o IP vai no relatório), detecção da
  placa Wi-Fi + redes por perto (`netsh wlan`), e **teste de velocidade Ookla**
  (`Test-InternetLocal` roda `speedtest.exe --format=jsonl`; `Invoke-SpeedtestStreaming`
  lê cada evento JSONL e `Write-EventoSpeedtest` → `Update-Speedtest` move o
  velocímetro ao vivo; resultado com provedor/servidor/IP/ping/jitter/perda/
  down/up + link Ookla). O `speedtest.exe` (Ookla CLI, proprietário) é colocado
  **manualmente em `tools/`** e **não vai ao repositório** (`.gitignore`); sem
  ele o teste mostra erro. O `Instalar-DICON.ps1` roda o binário uma vez com
  `--accept-license --accept-gdpr` (aceita a licença da Ookla na máquina; se não
  rodar, o DICON aceita no 1º uso mesmo assim — sempre passa as flags). Config em
  `config/rede-local.json`
  (`speedtest_server_id` — fixe o id de um servidor bom da região p/ pular as
  falhas do default; `speedtest_extra_args`; `speedtest_tentativas`, default 3;
  `speedtest_esperas_s`, default `[0,5,12]` s antes de cada tentativa no mesmo
  servidor). Se falhar, `Resolve-FalhaSpeedtest` classifica em
  `speedtest_falha_tipo` (`handshake` = nem baixou a config/lista de servidores
  da Ookla — link fraco/instável **ou servidor default sobrecarregado**;
  `bloqueio` = proxy/DNS barrando *.speedtest.net; `sem_binario`; `desconhecido`)
  e monta `speedtest_diagnostico`, uma frase que entra no JSON e no relatório PDF
  (box âmbar "Rede local fraca / instável") como **dado do laudo**, não só erro de
  ferramenta. Se a falha for `desconhecido` (ex.: `Latency test failed` /
  `[0] Unknown error`) **ou `handshake`** (o `Configuration - Timeout` costuma ser
  servidor default ruim, não a rede do local), tenta **outros servidores** da
  região: `Get-ServidoresSpeedtestProximos` (`speedtest.exe --servers` →
  `ConvertFrom-ListaServidoresSpeedtest`) e refaz contra até 3 IDs; se um
  funcionar, `servidor_fallback=$true` e o log sugere fixar aquele
  `speedtest_server_id` em `config/rede-local.json`.
  Se não houver rede no local, o técnico pode marcar **"testei pelo roteamento
  do celular"** e informar a **operadora** (vai no `rede_local` e no relatório).
  A **Fase 2 (com a VPN do TRE)** é a bateria de sempre (ping/iperf3/Selenium).
- **Selenium WebDriver** (geckodriver + chromedriver) — mede tempo de
  carregamento do sistema de totalização (app web), testado tanto no Firefox
  customizado usado em produção quanto no Chrome
- **Motor de decisão** — compara as métricas coletadas com limiares
  configuráveis e gera uma classificação final. Os limiares (v0.6.67+) têm **6
  perfis**: meio (`lan` / `wifi_local` / `celular`) × cenário (`sem_vpn` /
  `com_vpn`), resolvidos por `Get-PerfilLimiares` (`src/core/Limiares.ps1`) no
  shape plano que `Invoke-MotorDecisao` já consome. `perfis.lan`/`perfis.celular`
  são absolutos; `perfis.wifi_local` **herda da LAN + `folga`** (aditiva p/
  ms/%/s, *haircut* % p/ banda); o COM VPN de LAN/Celular vem semeado de SEM VPN
  + `orcamento_vpn` (botão "Recalcular" na tela do admin). "Na bateria" é por
  (meio × cenário × métrica). `carregamento_web_s` só existe COM VPN. O piso do
  "Limite" SEM VPN é ancorado nos valores de corte da ANATEL (Res. Interna
  444/2025 — SCM p/ LAN/Wi-Fi, SMP p/ celular). Formato/estrutura e valores
  provisórios em `docs/limiares-referencia.md` e `config/limiares.exemplo.json`.
  `Get-LimiaresConfig` sempre devolve o doc aninhado, com prioridade (v0.6.68):
  (1) cache `data/limiares.json` **se já for aninhado** (Web App novo ou "Salvar
  limiares" do admin); (2) `config/limiares.json|.exemplo.json` **se for aninhado**
  — assim um cache do Web App v1 (plano) não rebaixa os pisos ANATEL do pacote;
  (3) migra o que houver (`ConvertTo-PerfisLimiares`, cache antes do exemplo).
  `Sync-Limiares` não deixa uma resposta no formato plano sobrescrever um limiar
  aninhado local. `Atualizar-DICON.ps1` (v0.6.68) copia `config/*.exemplo.json`
  do pacote (aditivo — nunca toca nos `.json` reais). O `apps-script/Codigo.gs`
  já grava o JSON aninhado na célula A2 da aba `Limiares` mas **precisa de
  redeploy manual (clasp)** — até lá o config local é a fonte da verdade e a
  tela de Administração salva local (`Save-LimiaresLocal`)
- Saída em **JSON estruturado**, salva localmente primeiro; depois enviada via
  `Invoke-RestMethod` para o endpoint do Apps Script do Painel de Vistoria

## Convenções (mesmas do projeto trema-manutencao-tic)
- Encoding UTF-8 com BOM em todos os scripts
- Auto-elevação UAC quando necessário
- Log colorido em RichTextBox (fundo preto; cores: LightGreen, DeepPink, Cyan,
  Yellow, OrangeRed, SkyBlue)
- Uso de `Start-ProcessoNaoElevado` (ou equivalente) para lançar processos
  externos (iperf3.exe, geckodriver, chromedriver) sem herdar elevação
  desnecessária
- Nunca `[Parameter(Mandatory=$true)]` em parâmetros string de funções de log
- Preferência por soluções autocontidas — o ideal é o técnico rodar isso a
  partir de uma pasta única (executável + dependências), sem instalar nada
  extra no notebook de campo
- **Canais**: `main` = produção, `homologacao` = testes do admin. Instalação
  por `iex (irm .../<canal>/setup/Baixar-e-Instalar.ps1)` como **usuário
  comum**; pasta padrão `C:\Aplic\DICON` (main) / `C:\Aplic\DICON-HOMOLOG`
  (homologacao) — o script cria `C:\Aplic` sozinho; se não der, cai em
  `%LOCALAPPDATA%\...`. `setup/Preparar-Maquina.ps1` (admin) só é preciso se a
  raiz do C: estiver travada ou for máquina multiusuário. O setup grava
  `config/canal` (gitignored); `Atualizar-DICON.ps1` puxa desse canal sem
  parâmetro. `$CanalPadrao`/`$DeploymentIdPadrao` no `Baixar-e-Instalar.ps1` são
  de `homologacao` nesta branch e viram os de `main` no merge para `main`.
  `setup/Desinstalar-DICON.ps1` (v0.6.75+, também roda via `iex`) remove a
  instalação + atalho; **nunca apaga** se houver `resultados\pendentes\*.json`
  (diagnóstico de campo ainda não transmitido) a menos que `$env:DICON_FORCAR`
  — e mesmo assim faz uma cópia de segurança antes. Uso típico pra "trocar de
  versão do zero": rodar o desinstalador e depois o `Baixar-e-Instalar.ps1`.
  `Get-CanalInstalacao` (`src/core/Juntas.ps1`) lê `config/canal`; em
  `homologacao` a GUI mostra selos âmbar (`badgeHomologLogin` no login,
  `badgeHomologRail` no rail) e põe o sufixo `- HOMOLOGACAO` no título da janela.

## Telas (rail de navegação)
`login → início → guia de bordo → **Locais** → diagnóstico → administração`,
Grids empilhados alternados por `Visibility` (`$Global:Views`, `Show-View`).
O rail recolhe/expande (`btnRailToggle` → `Invoke-ToggleRail` / `Set-RailRecolhido`:
214 px ↔ 56 px só-ícones, oculta `railCabTexto`/`railRodape`/`lblNav*`;
estado em `$Global:RailRecolhido`, sessão).
**Auto-update**: ao entrar na home (e após "Atualizar dados"), `Test-AtualizacaoApp`
compara `$Global:VersaoApp` com `Get-VersaoRemota` (lê `ModuleVersion` do
`src/Conectividade.psd1` no canal de `config/canal`, no GitHub raw). Se houver
versão maior, o botão `btnAtualizarApp` (rodapé do rail) aparece → `Invoke-AtualizarApp`
(confirma, roda `setup/Atualizar-DICON.ps1 -Force` numa janela nova e fecha o DICON).
**Locais** (`viewLocais`, item `navLocais` no rail): tela de referência com os
locais de vistoria do roteiro do técnico (`Get-LocaisDoTecnico` achata
`$Global:RoteiroAtual.juntas[].locais[]`), grade `dgLocais` + busca livre
(`txtBuscaLocais`) + filtros por ZE (`cboFiltroZE`) e município (`cboFiltroMun`)
em `Update-LocaisFiltrados`; clicar numa linha da grade abre a **tela dedicada**
`viewLocalDetalhe` (`Invoke-AbrirLocalDetalhe`, que grava `$Global:LocalDetalheAtual`)
com a ficha completa do local (tipo, endereço, internet, UC, responsável/função,
telefone e `texto_completo` do roteiro); `btnLocalDetalheVoltar` →
`Invoke-VoltarAosLocais` volta à lista com os filtros preservados.
Essa tela tem, no topo, um **card STATUS DO LOCAL** com 5 indicadores
(`dot Ld Testado/Salvo/Transmitido/Exportado/Gel` — `Ellipse` vermelha quando
não / verde quando sim; `dotLdTestado` usa a cor do veredito) + `txtLdStatusInfo`
+ botão **`btnLdRelatorio`** ("Abrir relatório completo (PDF)" →
`Invoke-AbrirRelatorioLocal`: pega o último resultado salvo do Local em
`resultados/{pendentes,enviados}/`, **re-injeta o `vistoria_gel` atual**
(`New-BlocoVistoriaGel`, em `VistoriaGel.ps1` — usado também por `New-ResultadoJson`)
com o formulário GEL e as fotos que podem ter sido anexados **depois** do teste,
regenera o PDF via `Export-RelatorioPdf` e abre; só habilita se o Local já foi
testado). Tudo preenchido por `Update-StatusLocalDetalhe` a partir de
`Get-StatusLocal -LocalId` (`src/saida/Get-DiagnosticosRealizados.ps1` — junta
`Get-DiagnosticosRealizados` + varredura de `relatorios/*_<idSan>.{pdf,html}` +
`Get-VistoriaGel`). Logo abaixo, o **card do formulário GEL** (`cardGel` /
`btnAnexarGel` → `Invoke-AnexarGel` abre o PDF da vistoria do GEL, `Read-TextoPdf`
(PdfPig — 10 DLLs **versionadas** em `lib/pdfpig/`, como o iperf3; `Register-ResolucaoPdfLib`
instala um handler `AppDomain.AssemblyResolve` por nome simples para o .NET Framework
do PS 5.1 não brigar com as versões de `System.Buffers`/`System.Memory` etc.; se
as DLLs faltarem — instalação que atualizou de uma versão anterior do
`Atualizar-DICON.ps1` —, `Restore-PdfLib` baixa do GitHub raw do canal no 1º uso;
só aí degrada com aviso) + `ConvertFrom-VistoriaGel` extraem, **agrupados pelas
seções do GEL**: Coordenadas (lat/long/precisão); Tipo do local (esfera
administrativa, localização, tipo); Infraestrutura (salas, água, climatização,
iluminação, água potável, prédio em reforma); Instalações elétricas (quadro de
energia, energia, tomadas, tensão, extensão); Suporte ao link local (empresa,
telefone). O extrator é calibrado ao layout real do PDF do GEL (texto normalizado
sem acento; a resposta aparece **antes** do marcador `R. :` e o rótulo
`Coordenadas:` **depois** do valor; captura para no primeiro `?` para não invadir
a próxima pergunta). O técnico confere em `panelGelConf` (as mesmas 5 seções, uma
por sub-cabeçalho) e `Invoke-GelRegistrar` grava em `data/vistoria-gel/<localid>.json`
via `Save-VistoriaGel`; `btnGelRemover` → `Invoke-GelRemover`). **Fotos da vistoria**
(o app do GEL tira fotos que só ficam no GEL web): `btnGelAddFotos` →
`Invoke-GelAddFotos` aceita várias imagens de uma vez, `Resize-ImagemParaJpeg`
(WPF, respeita orientação EXIF) reduz cada uma p/ 1600 px / q80 e grava em
`data/vistoria-gel/<localid>/foto-NN.jpg`; `lstGelFotos` + `btnGelFotoRemover`
gerenciam a lista (`Get-FotosGel` / `Add-FotoGel` / `Remove-FotoGel`). As fotos
entram na seção "Fotos da vistoria" do relatório PDF (`Get-FotoGelDataUri`, grade
2-por-linha, teto ~12 MB) e **não** vão no JSON transmitido (só a contagem). O
anexo pode ser feito **a qualquer tempo**, não só no momento do teste — e é carregado do disco em
`$Global:VistoriaGel` quando o Local entra no assistente (passo 2). Vai para o
JSON `vistoria_gel` (com sub-objetos `tipo_local` / `infraestrutura` / `eletrica`
+ `fotos` = contagem) + seção "Vistoria GEL" no relatório (uma tabela por seção)
com link e imagem do Google Maps; a chave da **Maps Static API** fica em
`config/ambiente.json`
(`google_maps.static_key`), editável na tela de Administração; a imagem é baixada
e embutida como `data:` URI, então a chave não vai no HTML/PDF.

## Assistente de diagnóstico (GUI)
A tela de Diagnóstico é um **assistente de 5 ou 6 passos** (`viewDiag` com os
painéis `stepInfo/stepJunta/stepLocal/stepResultado/stepDecisao/stepFim` alternados
por `Visibility`; `$Global:WizardPassos`/`$Global:WizardNPassos` — montados por
`Set-ModoAssistente` ao abrir o assistente conforme o **modo de avaliação**;
navegação por `Show-WizardPasso` / `Invoke-WizardProximo` / `Invoke-WizardVoltar`,
que operam por **nome de painel**, com gates de justificativa só no modo completo).
**Modo de avaliação** (`modo_avaliacao` no doc de limiares, radio no topo da tela
de Administração; padrão **`medicao`** — ver `docs/modo-avaliacao.md`): `medicao` e
`referencia` = **5 passos** (pula `stepDecisao`), sem juízo de viabilidade (badges
"MEDIDO" neutros, passo 4 só com os valores — `referencia` acrescenta a faixa —,
recomendação vira **sugestão informativa** pelo maior download, relatório =
"Painel de Medições"); `completo` = **6 passos**, comportamento clássico (classifica,
recomenda o meio, "Painel de Viabilidade").
**Multi-meio (hub-and-spoke):** um Local pode ser medido por até 3 **meios** de
conexão — `lan` (rede cabeada), `wifi_local` (Wi-Fi do próprio local),
`celular` (Wi-Fi roteada de celular). Como a placa Wi-Fi só fica numa rede por
vez, os meios são testados em **sequência rígida** (LAN → Wi-Fi → Celular, ver
"Ordem fixa" adiante): só o **meio da vez** (`Get-MeioAtualPasso3` = 1º pendente
na ordem) fica ativo/clicável — os demais aparecem esmaecidos (`Opacity 0.45`),
mostrando as informações mas sem interação. O meio da vez já vem selecionado
(`$Global:MeioSelecionado` acompanha `Get-MeioAtualPasso3`); ao chegar a vez do
WI-FI a rede Wi-Fi conectada é tratada como a do local, ao chegar a do CELULAR
como roteamento do celular (aí a operadora, `cboOperadoraCel`, é obrigatória e só
editável nessa etapa). Cada meio gera uma
**medição** (Fase 1 Ookla + Fase 2 VPN) em `$Global:Medicoes`; meios que não
servem ao Local são marcados **"não aplicável" + motivo** (`$Global:MeiosNaoAplicaveis`).
Ao fim, o motor `Get-ConexaoRecomendada -Modo` (`src/decisao/Invoke-MotorDecisao.ps1`)
**recomenda o meio**. No modo `completo`: candidato = fechou Rede Local + VPN +
Fase 2, escolhido por melhor veredito e, no empate, maior download pela VPN; se
ninguém fechou a VPN, recomenda o de maior download na Rede Local, marcado
**provisório** e Local inviável; nada → "nenhuma"; o **veredito final do Local =
veredito do meio recomendado** (salvo override manual). Nos modos `medicao`/
`referencia`: **sugestão informativa** pelo maior download (VPN se houver, senão
rede local), `informativo=$true`, `veredito='medido'` — sem juízo, e o assistente
não tem o passo de decisão.

1. informação do teste → 2. Junta/Local (só o cartão de detalhe — o **anexo do
formulário GEL** saiu daqui e vive na tela `viewLocalDetalhe`) →
3. **meios de conexão** — *painel de 3 cards*: `Invoke-ProbeRedeLocal`
(`Invoke-FaseLocal -SemInternet`, async) inventaria as placas; cada card
(`cardLan`/`cardWifiPlaca`/`cardCelular`) tem o círculo numerado
(`numLan`/`numWifi`/`numCel`), um
`badge*` (NÃO TESTADO / TESTANDO… / TESTADO: <veredito> na cor do veredito /
NÃO SE APLICA - INVIÁVEL), um botão **`btnCheck{Lan,Wifi,Celular}`**
("Rodar checagem" / "Refazer checagem"), e o checkbox
"não se aplica a este local" — marcá-lo abre o card **`cardNaJustif`** abaixo da
grade (`Open-CardNaJustif`: `txtNaJustif` + `btnNaRegistrar`/`btnNaCancelar`,
`$Global:NaMeioPendente`); "Registrar" (`Invoke-NaRegistrar` → `Set-MeioNaoAplicavel`)
fecha o card e carimba a justificativa em vermelho no card do meio
(`txtNaMotivoCard*`), que fica inviável; desmarcar o checkbox remove o NA.
**Ordem fixa** (`$Global:OrdemMeios` = `lan`/`wifi_local`/`celular`): cada card traz
um **número num círculo** no canto superior esquerdo (`numLan`/`numWifi`/`numCel`
= 1/2/3 — cinza pendente, azul o meio da vez, verde resolvido). Só o **meio da vez**
(`Get-MeioAtualPasso3`) é interativo: `btnCheck*` e o checkbox "não se aplica" só
respondem nesse card (`Get-EstadoMeioPasso3` = `testado`/`na`/`pendente`;
`Test-MeioLiberadoNaOrdem` ainda existe como auxiliar). `Select-MeioParaChecar`
ignora clique em card fora da vez (loga a ordem). **Isolamento de rede por etapa**
(`cardMeioAviso`/`txtMeioAviso` na tela + `MessageBox` de `Invoke-CheckMeio` no
momento do "Rodar checagem", puladas em `$Global:ModoTeste`): na etapa da **LAN**
só o cabo pode estar conectado — se o Wi-Fi estiver num SSID, avisa para
desconectá-lo; se a LAN estiver sem link, avisa para **verificar o cabo e reler
só a placa LAN** (↻ do card LAN). Nas etapas **Wi-Fi/Celular** (mesma placa
sem-fio) a placa Wi-Fi tem de estar conectada e o **cabo de rede fora**. Ao
terminar a checagem da **LAN** (`Complete-CheckMeio` seta `$Global:AvisarRetirarCaboLan`),
`Close-OverlayCheck` mostra uma `MessageBox` lembrando de **tirar o cabo de rede**
antes do Wi-Fi. O **`btnWizProximo` só fica visível** quando os 3 meios estão
testados ou NA (qualquer combinação); `txtMeiosPendentes` explica quando está escondido.
**Congelamento**: assim que um meio é testado, `New-MedicaoAtual` guarda um
`snapshot_adaptador` (cópia dos dados da placa — IP/gateway/MAC…) na medição;
`Update-PainelMeios` (via `Get-MedicaoMeio`) passa a renderizar esse card **do
snapshot**, não do payload vivo — um probe geral ou o ↻ depois **não apagam** o
que o meio tinha no teste; só "Refazer checagem" renova.
**Releitura**: cada card tem um ↻ próprio (`btnRelerLan`/`btnRelerWifi`/`btnRelerCel`
+ `ringReler*`) → **`Invoke-RelerAdaptador 'lan'|'wifi'`** relê **só aquela placa**
(`Get-AdaptadorLan`/`Get-AdaptadorWireless` no runspace) e mescla no payload vivo
`$Global:FaseLocalPayload.Lan`/`.Wireless` (útil para os meios **ainda não
testados**); o ↻ do topo (`btnRelerPlacas`) relê tudo, sem tocar nos snapshots. Se o IP da placa LAN
começa com **10.11.** ou **10.198.** (`Test-RedeJusticaEleitoral`), o card LAN
mostra o selo verde **"REDE DA JUSTIÇA ELEITORAL"** (`cardLocJE`; também no JSON
`rede_local.lan_rede_je` e no PDF). Nesse caso, na checagem da **LAN** (v0.6.77+)
a Fase 2 **não espera o FortiClient** (`Test-RedeJeDireta` — só vale pro meio
LAN, checa a placa já congelada de `$Global:FaseLocalPayload.Lan`): o local já
está na rede interna da JE por link direto, então `Start-CheckFase2`/
`Start-DiagnosticoVpn`/`Update-EstadoVpn` liberam "Iniciar diagnóstico" direto
(mesmo estado `f2-vpn-ok`, texto "rede interna da JE" em vez de "VPN conectada")
e o iperf3/totalização são alcançados pela própria LAN. Wi-Fi só pela bandeja do Windows
(`cardWifiBandeja` explica). Clicar em "Rodar checagem" de um card →
**`Invoke-CheckMeio <meio>`** abre o **overlay modal `overlayCheck`**
(`$Global:CheckMeioAtivo`, uma checagem por vez) — **não roda sozinho**: o
técnico avança pelo botão `btnChkIniciar` (`Invoke-ChkAvancar`, texto/estado por
`$Global:ChkFase` via `Set-ChkBotao`): "Iniciar" → **Fase 1**
(`Start-CheckFase1`→`Complete-CheckFase1`: `Invoke-FaseLocal` via
`Start-TarefaRede`, velocímetro Ookla) → botão vira "Testar a VPN" → **Fase 2**:
`Start-CheckFase2` **só verifica a VPN** (`Update-EstadoVpn`/`Get-DetalheVpn`/
`Test-VpnAtiva`/`btnAbrirFortiClient`/`btnReverificarVpn`) — com a VPN conectada,
mostra IP da VPN/interface/DNS em verde e o estado vira `f2-vpn-ok` com o botão
"Iniciar diagnóstico com a VPN"; só esse clique roda `Start-DiagnosticoVpn` →
`Start-DiagnosticoAssincrono -AoConcluir` = ping + `Test-BandaVpn` + Selenium
(velocímetro iperf3) → `Complete-CheckFase2`. Se a VPN estiver fora,
`btnChkVpnImpossivel`→`Invoke-CheckVpnImpossivel` com motivo →
`Set-DiagnosticoVpnImpossivel`, meio inviável → **Fase 3** (Selenium, "em
implementação"). `Complete-CheckMeio` → `Add-MedicaoAtual`; `Close-OverlayCheck`
(`btnChkFechar`) fecha. O corpo tem um stepper de 3 linhas
(`txtChkS1/S2/S3`+`dotChkS1/S2/S3`) e **3 colunas** — Origem (Servidor/IP,
`grpF1Conn`/`grpF2Conn`) · Medição (velocímetro, `Set-ChkFaseView` alterna
Fase 1 ↔ Fase 2) · Resultado — e abaixo o log (`lstLog`) em coluna única. Ao
concluir, o card fica **verde/amarelo/vermelho**
conforme o veredito. `cardRecMeios`/`txtRecMeios` (`Update-BannerRecomendacao`)
mostra a recomendação assim que 1+ meio é testado. Trocar de Local zera as
medições (`Reset-Medicoes`); o gate 3→4 exige 1+ meio testado (ou todos "não
aplicável" → medição sintética inviável)
→ 4. resultado por métrica: `Update-SeletorMedicoes` monta **uma aba por meio
testado** no `TabControl` `tabsMedicoes` (styles `TabsMedicao`/`TabMedicao` em
Tema.xaml — aba selada em azul, header = bolinha na cor do veredito + rótulo +
palavra do veredito em cinza); `Show-MedicaoNoPasso5`/`Invoke-TrocarMedicaoPasso5`
trocam qual medição os grids mostram; `Save-AjustesPasso5` grava classe final +
justificativa na medição **aberta**. Dois cards, cada um com sua tabela: **"Com a
VPN"** (`dgAvaliacaoVpn`, linhas da Fase 2) e **"Rede local — Speedtest da Ookla
(sem VPN)"** (`cardAvaliacaoRl`/`dgAvaliacaoRl`, linhas da Fase 1 —
`Get-DetalhesRedeLocal` classifica o teste de velocidade contra o perfil
**`sem_vpn` do meio da vez** (`Get-PerfilLimiares`; a Fase 2 usa o `com_vpn`),
métricas `rl_*`, sem carregamento_web). As duas famílias entram no pior caso
(`$Global:AvaliacaoRows` = união; `Update-DecisaoRecalculada`). `txtRedeLocalNota`
(no card RL) explica / mostra o motivo se a rede local não mediu. No JSON:
`rede_local.internet_avaliacao` e
`medicoes[].rede_local_avaliacao`; no PDF, tabela "Avaliação da rede local (sem
VPN)". `cardNaResumo`/`txtNaResumo` lista os meios
marcados "não aplicável" (rótulo — motivo); se nenhum meio foi testado (todos
"não aplicável"), `txtSemMedicoes` avisa que o local fica inviável →
5. **conexão recomendada**:
combo `cboConexaoRec` (candidatos + "nenhuma") pré-selecionado por
`Get-ConexaoRecomendada`, `txtMotivoRec` (**motivo obrigatório**,
`Test-RecomendacaoValida` é o gate 5→6) e a tabela read-only `dgMedicoes` de
todas as medições do Local; o card da recomendação final (rótulo "RECOMENDAÇÃO
FINAL", override manual do veredito) continua acima →
6. conclusão: **Salvar** / **Transmitir** / **Exportar relatório (PDF)** + checklist.
Os runspaces são `Start-TarefaRede` (`$Global:TarefaRedeState`, Fase 1/probe) e
`Start-DiagnosticoAssincrono` (`$Global:DiagRunState`, Fase 2, com `-AoConcluir`).
O `rede_local` entra no JSON de resultado (`New-ResultadoJson -FaseLocal`) e numa
seção própria do relatório PDF; `medicoes[]` + `conexao_recomendada`
(`-Medicoes` / `-ConexaoRecomendada` / `-MotivoRecomendacao`) trazem o
multi-meio, com bloco em destaque + tabela de meios no PDF.
### Relatório PDF (`src/saida/Export-RelatorioPdf.ps1`)
Monta um HTML **em paisagem** (`@page size: A4 landscape`), nos moldes do "Painel
da Vistoria" da SEMAP, e converte com o Edge/Chrome headless (`--print-to-pdf`,
`--no-pdf-header-footer`); sem navegador, salva o HTML. Saída em `relatorios/`
(gitignored). `New-RelatorioHtml -Resultado <json>` tem 6 seções. A **seção 3**
depende do `modo_avaliacao` do JSON: `medicao`/`referencia` → **`Get-PainelMedicoesHtml`**
("Painel de Medições": Identificação + Resumo + tabela "Medições por meio" com os
valores, sem KPIs de viáveis/inviáveis nem "Conclusão do diagnóstico"; `referencia`
mostra também a faixa nas tabelas por meio via `Get-TabelaAvaliacaoHtml -Modo`).
`completo` → `Get-PainelHtml` (abaixo). `Get-MeioBlocoHtml -Modo` tira o badge de
veredito do título fora do `completo`.
1. **Cabeçalho** JE / TRE-MA / SEASU-COINF-STIC / DICON.
2. **Título + subtítulo** — "Relatório de Diagnóstico de Conectividade" + "ZE N —
   Município (sede: X)".
3. **Painel de Viabilidade de Conectividade** (`Get-PainelHtml`, modo `completo`): faixa navy +
   Identificação (kv) + Indicadores (KPIs: meios testados / viáveis / com ressalva
   / inviáveis / não aplicáveis / conectou à VPN) + Situação por meio (tabela com
   colunas "Sem VPN conectada" / "Com VPN conectada" / Download com VPN / Latência
   com VPN, linha do recomendado em azul, inviável em vermelho) + **Conclusão do
   diagnóstico** (Recomendação final, Classificação do local, Conexão recomendada,
   Motivo, Ajuste, Condicionantes/pendências `Get-CondicionantesDiag`, Observações
   finais `Get-ObservacoesFinaisDiag` — prosa gerada pelo veredito).
4. **Testes de comunicação por meio** (`Get-MeioBlocoHtml`, ordem LAN / Wi-Fi do
   local / Celular): por meio, "Sem VPN conectada — teste de velocidade"
   (`rede_local_avaliacao[]`) + "Com VPN conectada — diagnóstico pela VPN da JE"
   (o meio recomendado usa `avaliacao[]` com faixa+motivo; os demais, os números
   crus). Meios "não aplicável" viram uma linha só com o motivo.
   **Nomes de produto** (speedtest/Ookla/iperf3/Selenium) não aparecem em texto
   visível — só "teste de velocidade", "banda pela VPN", "análise de banda",
   "sistema de totalização"; chaves de config (`speedtest_server_id`), nomes de
   função e o binário `speedtest.exe` seguem como estão.
5. **Dados da vistoria do GEL** — as seções do `vistoria_gel` (sem as fotos).
6. **Registro fotográfico** — `Get-FotosGel`, grade de 3 por linha com legenda
   "Foto N", teto ~14 MB embutido.
O `rede_local` / `medicoes[]` / `conexao_recomendada` continuam no JSON de
resultado (`New-ResultadoJson`).

## Envio de resultados
- **Modo `offline-first`** (`config/envio.json`): "Salvar resultado" grava em
  `resultados/pendentes/`; o envio ao Web App acontece depois — no botão
  "Atualizar dados" (com internet) ou no aviso "Reenviar" da tela inicial.
- Destino: **planilha Google dedicada só a resultados de conectividade**
  (`PLANILHA_RESULTADOS_ID` em `apps-script/Codigo.gs`, aba `Resultados`).
  `gravarResultado` (v0.6.73: via API do Sheets/`UrlFetchApp`, token de
  serviço — ver "Transporte" abaixo) grava por nome de coluna, incluindo
  `conexao_recomendada` / `operadora_recomendada` / `veredito_recomendado` /
  `recomendacao_provisoria` / `motivo_recomendacao`; colunas novas no futuro
  são um passo manual (`setupServiceAuth`/`setupAdminPin`/`setupResultados`
  são todos assim — a migração automática de colunas saiu). O JSON completo,
  com `medicoes[]`, fica na coluna `json`. **Deploy do Apps Script é manual
  (clasp) — não implantar sem o admin.**
- `Send-Resultado` só move para `resultados/enviados/` com resposta
  `{status:'ok'}`; `erro`/`ignorado` mantêm o arquivo em `pendentes/`.
- Teste: `tools/Testar-Envio.ps1` (HttpListener local simula o Apps Script).
- **Transporte: Apps Script Execution API (v0.6.73, `src/core/AppsScriptApi.ps1`)**:
  o DICON chama `POST script.googleapis.com/v1/scripts/{deployment_id}:run`
  (`function:'executar'`, `apps-script/Codigo.gs`) em vez da URL `/exec` do Web
  App — testado ao vivo que um Web App `access: DOMAIN` **ignora** um
  `Authorization: Bearer` (só aceita sessão de navegador). `Invoke-FuncaoAppsScript`
  é a única chamada (usada por `Sync-Juntas`/`Sync-Tecnicos`/`Sync-Roteiros`/
  `Sync-Limiares`, `Save-Limiares`, `Send-Resultado`); `deployment_id` vem de
  `config/juntas.json`. A função `executar` roda **como quem chamou** — por
  isso juntas/técnicos/roteiros/limiares (não sensíveis) usam `SpreadsheetApp`
  normal, mas a gravação de Resultados (sensível: IP/nome/telefone) usa a API
  do Sheets via `UrlFetchApp` autenticada com um **token de serviço do George**
  guardado nas Propriedades do Script (`setupServiceAuth`,
  `tools/Extrair-TokenServico.ps1`) — grava sempre "como George", não importa
  qual técnico chamou.
- **Autenticação Google (v0.6.69+, `src/core/AuthGoogle.ps1`)**: quando
  `config/ambiente.json > google_oauth.enabled` (padrão `false`), toda chamada
  leva `Authorization: Bearer <token>` de uma conta `@tre-ma.jus.br`.
  `Get-CabecalhoAuthWebApp` (=`@{}` se desligado) resolve/renova o token;
  refresh token guardado com **DPAPI** em
  `%LOCALAPPDATA%\DICON\google-refresh.dat` (por usuário Windows). Consentimento
  **1×/máquina**: loopback `127.0.0.1` (PKCE, sem admin) ou fallback device‑code.
  UI: card **"Conta Google"** em Administração (`btnConectarGoogle`/`btnDesconectarGoogle`,
  `panelDeviceCode`); login e "Atualizar dados" tratam o erro `CONECTAR_GOOGLE`
  chamando `Invoke-ConectarGoogle`. `Codigo.gs` grava `enviado_por` (email de
  quem chamou — confiável na Execution API). Setup GCP (projeto padrão +
  Executável de API) + rollout em `docs/oauth-google.md`. Teste:
  `tools/Testar-AuthGoogle.ps1`, `tools/Testar-Envio.ps1`.

## Ainda em aberto
- Limiares exatos de latência/perda/banda/tempo de carregamento por meio ×
  cenário (v0.6.67 trouxe os 6 perfis com base ANATEL para o SEM VPN e um
  orçamento de VPN provisório para o COM VPN; falta calibrar em campo/homologação
  contra `10.11.1.38` e com o time da totalização) — ver
  `docs/limiares-referencia.md`
- **Migrar para a Execution API em homologação e depois produção** (v0.6.73):
  associar o projeto do Apps Script a um projeto GCP padrão (`dicon-oauth`),
  ativar a Apps Script API nele, `clasp push` + redeploy (implanta
  `executionApi` junto do `webapp`), reconectar a Conta Google (escopos
  novos), rodar `setupServiceAuth` (via `tools/Extrair-TokenServico.ps1`) e
  atualizar `config/juntas.json > deployment_id` nas máquinas já instaladas. Até
  lá o config/cache local manda. Ver `docs/oauth-google.md`.
- Coleta real das métricas da Fase 2 (iperf3 + Selenium + ping) validada ponta a
  ponta (a Fase 1 — rede local — já coleta de verdade)
- Checagem por meio via overlay modal (v0.6.29+, rollback: tag
  `backup-pre-checkmeio`): falta validar na GUI ponta a ponta em campo;
  Selenium/carregamento web (Fase 3) segue "em implementação"; "motivo da
  recomendação" é obrigatório sempre (provisório)
- Fase 2 do admin: incluir/alterar Locais das Juntas
- Empacotamento de campo (pasta portátil autocontida)