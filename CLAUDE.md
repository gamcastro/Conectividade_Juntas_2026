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
  ele o teste mostra erro. Config em `config/rede-local.json`
  (`speedtest_server_id`, `speedtest_extra_args`). Até **3 tentativas** (espera
  0s/3s/6s). Se falhar, `Resolve-FalhaSpeedtest` classifica em
  `speedtest_falha_tipo` (`handshake` = nem baixou a config/lista de servidores
  da Ookla — link fraco/instável; `bloqueio` = proxy/DNS barrando *.speedtest.net;
  `sem_binario`; `desconhecido`) e monta `speedtest_diagnostico`, uma frase que
  entra no JSON e no relatório PDF (box âmbar "Rede local fraca / instável") como
  **dado do laudo**, não só erro de ferramenta.
  Se não houver rede no local, o técnico pode marcar **"testei pelo roteamento
  do celular"** e informar a **operadora** (vai no `rede_local` e no relatório).
  A **Fase 2 (com a VPN do TRE)** é a bateria de sempre (ping/iperf3/Selenium).
- **Selenium WebDriver** (geckodriver + chromedriver) — mede tempo de
  carregamento do sistema de totalização (app web), testado tanto no Firefox
  customizado usado em produção quanto no Chrome
- **Motor de decisão** — compara as métricas coletadas com limiares
  configuráveis e gera uma classificação final
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
  parâmetro. `$CanalPadrao`/`$EndpointPadrao` no `Baixar-e-Instalar.ps1` são de
  `homologacao` nesta branch e viram os de `main` no merge para `main`.
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
`viewLocalDetalhe` (`Invoke-AbrirLocalDetalhe`) com a ficha completa do local
(tipo, endereço, internet, UC, responsável/função, telefone e `texto_completo`
do roteiro); `btnLocalDetalheVoltar` → `Invoke-VoltarAosLocais` volta à lista
com os filtros preservados.

## Assistente de diagnóstico (GUI)
A tela de Diagnóstico é um **assistente de 6 passos** (`viewDiag` com os painéis
`stepInfo/stepJunta/stepLocal/stepResultado/stepDecisao/stepFim` alternados por
`Visibility`; `$Global:WizardPassos`/`$Global:WizardNPassos`; navegação por
`Show-WizardPasso` / `Invoke-WizardProximo` / `Invoke-WizardVoltar`, com gates de
justificativa):
**Multi-meio (hub-and-spoke):** um Local pode ser medido por até 3 **meios** de
conexão — `lan` (rede cabeada), `wifi_local` (Wi-Fi do próprio local),
`celular` (Wi-Fi roteada de celular). Como a placa Wi-Fi só fica numa rede por
vez, o técnico **clica no card** do meio que vai testar (LAN / WI-FI / CELULAR)
— `Select-MeioParaChecar` grava `$Global:MeioSelecionado`, o card ganha **borda
azul** e só o seu `btnCheck*` fica habilitado; clicar em WI-FI declara que a
rede conectada é a do local, clicar em CELULAR declara que é o roteamento do
celular (aí a operadora é obrigatória). Se só a LAN estiver conectada, ela já
vem selecionada. Cada meio gera uma
**medição** (Fase 1 Ookla + Fase 2 VPN) em `$Global:Medicoes`; meios que não
servem ao Local são marcados **"não aplicável" + motivo** (`$Global:MeiosNaoAplicaveis`).
Ao fim, o motor `Get-ConexaoRecomendada` (`src/decisao/Invoke-MotorDecisao.ps1`)
**recomenda o meio**: candidato = fechou Rede Local + VPN + Fase 2, escolhido por
melhor veredito e, no empate, maior download pela VPN; se ninguém fechou a VPN,
recomenda o de maior download na Rede Local, marcado **provisório** e Local
inviável; nada → "nenhuma". O **veredito final do Local = veredito do meio
recomendado** (salvo override manual do técnico no combo da recomendação final).

1. informação do teste → 2. Junta/Local (com cartão de detalhe) →
3. **meios de conexão** — *painel de 3 cards*: `Invoke-ProbeRedeLocal`
(`Invoke-FaseLocal -SemInternet`, async) inventaria as placas; cada card
(`cardLan`/`cardWifiPlaca`/`cardCelular`, clicáveis para selecionar) tem um
`badge*` (NÃO TESTADO / TESTANDO… / TESTADO: <veredito> na cor do veredito /
NÃO SE APLICA - INVIÁVEL), um botão **`btnCheck{Lan,Wifi,Celular}`**
("Rodar checagem", habilitado só no card selecionado e conectado), e o checkbox
"não se aplica a este local" — marcá-lo abre o card **`cardNaJustif`** abaixo da
grade (`Open-CardNaJustif`: `txtNaJustif` + `btnNaRegistrar`/`btnNaCancelar`,
`$Global:NaMeioPendente`); "Registrar" (`Invoke-NaRegistrar` → `Set-MeioNaoAplicavel`)
fecha o card e carimba a justificativa em vermelho no card do meio
(`txtNaMotivoCard*`), que fica inviável; desmarcar o checkbox remove o NA.
**Releitura**: cada card tem um ↻ próprio (`btnRelerLan`/`btnRelerWifi`/`btnRelerCel`
+ `ringReler*`) → **`Invoke-RelerAdaptador 'lan'|'wifi'`** relê **só aquela placa**
(`Get-AdaptadorLan`/`Get-AdaptadorWireless` no runspace) e mescla em
`$Global:FaseLocalPayload.Lan`/`.Wireless`, **preservando o outro card** (cenário:
testei a LAN, tirei o cabo, liguei o Wi-Fi — o card LAN mantém o IP/gateway já
coletados); o ↻ do topo (`btnRelerPlacas`) ainda relê tudo. Se o IP da placa LAN
começa com **10.11.** ou **10.198.** (`Test-RedeJusticaEleitoral`), o card LAN
mostra o selo verde **"REDE DA JUSTIÇA ELEITORAL"** (`cardLocJE`; também no JSON
`rede_local.lan_rede_je` e no PDF). Wi-Fi só pela bandeja do Windows
(`cardWifiBandeja` explica). Clicar em "Rodar checagem" de um card →
**`Invoke-CheckMeio <meio>`** abre o **overlay modal `overlayCheck`**
(`$Global:CheckMeioAtivo`, uma checagem por vez) — **não roda sozinho**: o
técnico avança pelo botão `btnChkIniciar` (`Invoke-ChkAvancar`, texto/estado por
`$Global:ChkFase` via `Set-ChkBotao`): "Iniciar" → **Fase 1**
(`Start-CheckFase1`→`Complete-CheckFase1`: `Invoke-FaseLocal` via
`Start-TarefaRede`, velocímetro Ookla) → botão vira "Testar a VPN" → **Fase 2**
(`Start-CheckFase2`→`Complete-CheckFase2`: gate da VPN `Update-EstadoVpn`/
`Test-VpnAtiva`/`btnAbrirFortiClient`; se OK, `Start-DiagnosticoAssincrono
-AoConcluir` = ping + `Test-BandaVpn` + Selenium, velocímetro iperf3; se VPN
fora, `btnChkVpnImpossivel`→`Invoke-CheckVpnImpossivel` com motivo →
`Set-DiagnosticoVpnImpossivel`, meio inviável) → **Fase 3** (Selenium, "em
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
`Get-DetalhesRedeLocal` classifica o Speedtest contra os mesmos limiares,
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
O relatório (`src/saida/Export-RelatorioPdf.ps1`) monta um HTML no padrão TRE-MA
e converte com o Edge/Chrome headless (`--print-to-pdf`); sem navegador, salva o
HTML. Saída em `relatorios/` (gitignored).

## Envio de resultados
- **Modo `offline-first`** (`config/envio.json`): "Salvar resultado" grava em
  `resultados/pendentes/`; o envio ao Web App acontece depois — no botão
  "Atualizar dados" (com internet) ou no aviso "Reenviar" da tela inicial.
- Destino: **planilha Google dedicada só a resultados de conectividade**
  (`PLANILHA_RESULTADOS_ID` em `apps-script/Codigo.gs`, aba `Resultados` criada
  pelo próprio script). Web App na **v8** (POST `acao:'resultado'` ativo).
  `gravarResultado` grava por nome de coluna e inclui `conexao_recomendada` /
  `operadora_recomendada` / `veredito_recomendado` / `recomendacao_provisoria` /
  `motivo_recomendacao` (migra planilhas antigas via `insertColumnsBefore`); o
  JSON completo, com `medicoes[]`, fica na coluna `json`. **Deploy do Web App é
  manual (clasp) — não implantar sem o admin.**
- `Send-Resultado` só move para `resultados/enviados/` com resposta
  `{status:'ok'}`; `erro`/`ignorado` mantêm o arquivo em `pendentes/`.
- Teste: `tools/Testar-Envio.ps1` (HttpListener local simula o Apps Script).

## Ainda em aberto
- Limiares exatos de latência/perda/banda/tempo de carregamento que definem
  viável vs inviável (depende de validação com o time responsável pelo sistema
  de totalização)
- Coleta real das métricas da Fase 2 (iperf3 + Selenium + ping) validada ponta a
  ponta (a Fase 1 — rede local — já coleta de verdade)
- Checagem por meio via overlay modal (v0.6.29+, rollback: tag
  `backup-pre-checkmeio`): falta validar na GUI ponta a ponta em campo;
  Selenium/carregamento web (Fase 3) segue "em implementação"; "motivo da
  recomendação" é obrigatório sempre (provisório)
- Fase 2 do admin: incluir/alterar Locais das Juntas
- Empacotamento de campo (pasta portátil autocontida)