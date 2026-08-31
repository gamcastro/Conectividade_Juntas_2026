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
- **iperf3** (client Windows) — banda real, contra servidor iperf3 rodando num
  Ubuntu no CPD (via VPN)
- **Ping nativo do Windows** — latência, jitter e perda
- **Fase 1 — rede local (ANTES da VPN do TRE)** (`src/core/RedeLocal.ps1`,
  `Invoke-FaseLocal`): inventário da placa cabeada (LAN conectada? **IP local**,
  máscara, gateway, DNS, MAC, velocidade — o IP vai no relatório), detecção da
  placa Wi-Fi + redes por perto (`netsh wlan`), conexão a um Wi-Fi WPA2 por
  dentro da ferramenta (`Connect-RedeWireless`), e checagem da internet do local
  (ping público + DNS + mini-download; alvos em `config/rede-local.json`).
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

## Assistente de diagnóstico (GUI)
A tela de Diagnóstico é um **assistente de 7 passos** (`viewDiag` com os painéis
`stepInfo/stepJunta/stepLocal/stepDiag/stepResultado/stepDecisao/stepFim`
alternados por `Visibility`; estado em `$Global:WizardStep`, navegação por
`Show-WizardPasso` / `Invoke-WizardProximo` / `Invoke-WizardVoltar`, com gates de
justificativa):
1. informação do teste → 2. Junta/Local (com cartão de detalhe) →
3. **rede local, SEM a VPN**: ao entrar, `Invoke-ProbeRedeLocal`
(`Invoke-FaseLocal -SemInternet`, async) inventaria as placas com indicador
verde/vermelho de LAN e Wi-Fi; "Rodar checagem local" (`Invoke-RodarFaseLocal` →
`Complete-FaseLocal`) só habilita se houver conexão (cabo ou Wi-Fi) e faz o
teste de internet (ping/DNS/download) num painel próprio; "teste pelo celular"
(tethering + operadora) só habilita quando NÃO há cabo e existe placa Wi-Fi;
trocar de Local / voltar ao passo 2 zera a checagem
→ 4. rodar a bateria **com a VPN** (auto-avança ao concluir) → 5. resultado por
métrica → 6. decisão final → 7. conclusão: **Salvar** / **Transmitir** /
**Exportar relatório (PDF)** + checklist.
O runspace da fase local / conexão Wi-Fi é o `Start-TarefaRede`
(`$Global:TarefaRedeState`, mesmo padrão do `Start-DiagnosticoAssincrono`).
O `rede_local` entra no JSON de resultado (`New-ResultadoJson -FaseLocal`) e numa
seção própria do relatório PDF.
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
- `Send-Resultado` só move para `resultados/enviados/` com resposta
  `{status:'ok'}`; `erro`/`ignorado` mantêm o arquivo em `pendentes/`.
- Teste: `tools/Testar-Envio.ps1` (HttpListener local simula o Apps Script).

## Ainda em aberto
- Limiares exatos de latência/perda/banda/tempo de carregamento que definem
  viável vs inviável (depende de validação com o time responsável pelo sistema
  de totalização)
- Coleta real das métricas da Fase 2 (iperf3 + Selenium + ping) validada ponta a
  ponta (a Fase 1 — rede local — já coleta de verdade)
- Fase 2 do admin: incluir/alterar Locais das Juntas
- Empacotamento de campo (pasta portátil autocontida)