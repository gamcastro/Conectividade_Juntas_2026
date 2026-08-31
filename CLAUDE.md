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

## Envio de resultados
- **Modo `offline-first`** (`config/envio.json`): "Salvar resultado" grava em
  `resultados/pendentes/`; o envio ao Web App acontece depois — no botão
  "Atualizar dados" (com internet) ou no aviso "Reenviar" da tela inicial.
- Destino: **planilha Google dedicada só a resultados de conectividade**
  (`PLANILHA_RESULTADOS_ID` em `apps-script/Codigo.gs`, aba `Resultados`).
- `Send-Resultado` só move para `resultados/enviados/` com resposta
  `{status:'ok'}`; `erro`/`ignorado` mantêm o arquivo em `pendentes/`.
- Teste: `tools/Testar-Envio.ps1` (HttpListener local simula o Apps Script).

## Ainda em aberto
- Limiares exatos de latência/perda/banda/tempo de carregamento que definem
  viável vs inviável (depende de validação com o time responsável pelo sistema
  de totalização)
- `PLANILHA_RESULTADOS_ID` a preencher quando a planilha de resultados existir
  (hoje o Web App responde `{status:'ignorado'}` e o resultado fica em
  `pendentes/`)
- Coleta real das métricas (iperf3 + Selenium + ping) validada ponta a ponta
- Fase 2 do admin: incluir/alterar Locais das Juntas
- Empacotamento de campo (pasta portátil autocontida)