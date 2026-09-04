# Autenticação Google (OAuth) no cliente DICON

## Por quê

O Web App do Apps Script era publicado com acesso **"Qualquer pessoa" (anônimo)**.
A política do Workspace do TRE‑MA **desabilitou publicar/atualizar Web App anônimo**
→ o `clasp redeploy` fica travado. A saída óbvia parecia ser publicar como
**"Qualquer pessoa do domínio" (`access: DOMAIN`)** e mandar um token OAuth em
`Authorization: Bearer` — **mas isso não funciona**: testado ao vivo (v0.6.69–72),
um Web App com `access: DOMAIN` na URL `/exec` **ignora completamente** o
cabeçalho `Authorization`, mesmo com um token válido e com o escopo certo — ele
só reconhece **sessão de navegador** (cookie do Google). Um programa (o DICON)
nunca tem isso.

## A solução real: Apps Script Execution API

A forma correta do Google para chamar uma função de um script com um token
OAuth de verdade é a **Execution API** —
`POST https://script.googleapis.com/v1/scripts/{deployment_id}:run`,
`{"function":"executar","parameters":[{...}]}` — documentada em
[Execute functions with the Apps Script API](https://developers.google.com/apps-script/api/how-tos/execute)
e [Method: scripts.run](https://developers.google.com/apps-script/api/reference/rest/v1/scripts/run).
Isso **funciona** com um token Bearer comum. Duas implicações mudam o desenho:

1. **Setup**: o projeto do Apps Script precisa estar associado a um **projeto
   GCP padrão** (não o "Padrão" oculto que cada script ganha por default) com
   a **Apps Script API ativada**, e implantado como **"Executável de API"**.
2. **Identidade de execução**: a função roda **como quem chamou** (o técnico),
   não "como eu" (George) — diferente do Web App com `executeAs: USER_DEPLOYING`.
   Ótimo pra leitura (juntas/técnicos/roteiros/limiares não são dados
   sensíveis). Ruim pra escrita em **Resultados** (IP/nome/telefone do local):
   se cada técnico precisasse de acesso Editor direto à planilha pra gravar,
   qualquer um veria os dados de todos.

**Como o DICON contorna o problema 2**: só a leitura (`juntas`/`tecnicos`/
`roteiros`/`limiares`) e o salvar limiares (admin, com PIN) usam
`SpreadsheetApp` normal, rodando como o técnico chamador — que só precisa de
acesso **Leitor** nas 3 planilhas de referência. A gravação de **Resultados**
usa a API do Sheets via `UrlFetchApp`, autenticada com um **token de serviço
do próprio George** guardado nas Propriedades do Script — grava sempre "como
George", não importa qual técnico chamou.

## Estado atual

- **Homologação e produção: migradas (v0.6.73/v0.7.6, 2026-09-04).** Credencial
  Desktop do projeto GCP `dicon-oauth` (org `tre-ma.jus.br`, consentimento
  **Interno**), compartilhado pelos dois ambientes. Escopos: `openid` +
  `userinfo.email` + **`spreadsheets`** + **`script.external_request`** (os que
  o `Codigo.gs` de fato usa — `SpreadsheetApp` + `UrlFetchApp` — a Execution API
  exige token com **todos** os escopos do script, não só os da função chamada).
  Token de serviço (`setupServiceAuth`) configurado nos dois projetos.
- **Produção tem DOIS deployments** (a política do Workspace bloqueia
  reimplantar algo que já tem acesso anônimo, mesmo só pra acrescentar a
  Execution API — ver `apps-script/CLASP.md` "Tentativa que não funcionou"):
  a implantação **antiga** (`/exec` anônimo) fica **congelada pra sempre**,
  servindo quem ainda não atualizou o DICON; uma implantação **nova**
  (`webapp: DOMAIN` + `executionApi: DOMAIN`) é a que `v0.7.6+` usa. Nenhum
  técnico em campo foi afetado — o `/exec` antigo segue idêntico.

## Setup no Google Cloud (uma vez por ambiente)

1. **Projeto GCP**: `dicon-oauth` (ou outro projeto GCP **padrão**, criado
   direto no Console — não o "Padrão" oculto que o Apps Script cria sozinho).
2. **Tela de consentimento OAuth**: **"Interno"** (só `@tre-ma.jus.br`, sem
   verificação do Google — exige o projeto estar na organização Cloud do
   TRE‑MA). Escopos: `openid`, `userinfo.email`, `spreadsheets`,
   `script.external_request` (os dois últimos aparecem como "sem API
   ativada" na tela — adicione pela caixa "Adicionar escopos manualmente"
   colando a URL do escopo).
3. **Credencial** (Credenciais → Criar credenciais → ID do cliente OAuth):
   tipo **"App para computador" (Desktop app)**. Copie `client_id` e
   `client_secret`.
   > Para app instalado, o `client_secret` **não é confidencial** (RFC 8252).
   > A segurança vem do **PKCE** + redirect em `127.0.0.1`. Pode ser
   > commitado no repositório (o GitHub push protection pode bloquear o
   > push — libere pelo link que ele mostra, motivo "It's used in tests").

## Associar o Apps Script ao projeto GCP + implantar como Executável de API

1. No editor do Apps Script (homologação ou produção) → ⚙ Configurações do
   projeto → "Projeto do Google Cloud" → **Alterar projeto** → cole o
   **número** do projeto `dicon-oauth` (não o ID — o número aparece em
   `console.cloud.google.com/home/dashboard?project=dicon-oauth`).
2. Ative a Apps Script API **nesse** projeto GCP:
   `console.cloud.google.com/apis/library/script.googleapis.com?project=dicon-oauth`
   → Ativar.
3. `clasp push` (feito por mim) já leva o `appsscript.json` com
   `"executionApi": {"access": "DOMAIN"}` ao lado do `webapp` — o
   `clasp create-deployment`/`redeploy` de sempre passa a implantar os dois
   tipos juntos (mesma URL/ID de sempre).

## Token de serviço (grava Resultados sempre "como George")

1. Depois que `config/ambiente.exemplo.json` tiver os escopos novos
   (`spreadsheets` + `script.external_request`), o George conecta de novo:
   **Administração → Conta Google → Desconectar → Conectar** (o navegador
   pede a permissão nova de Sheets).
2. Roda `tools/Extrair-TokenServico.ps1` (reaproveita `Get-RefreshTokenGoogle`
   já existente) — imprime uma linha pronta pra colar.
3. No editor do Apps Script: **Executar → `setupServiceAuth`**, cola os 3
   argumentos impressos (`client_id`, `client_secret`, `refresh_token`).
   Autoriza a execução (é o George rodando no próprio editor). Feito — fica
   guardado nas Propriedades do Script; `gravarResultado` renova sozinho.

## Como o técnico conecta

- 1º uso: abre o navegador → escolhe a conta `@tre-ma.jus.br` (já logado no
  Google corporativo → 2 cliques) → **Permitir** (agora inclui "Ver, editar,
  criar e excluir suas planilhas do Google Sheets" — é o escopo que a
  Execution API exige pra rodar qualquer função do script, mesmo uma leitura;
  a permissão real de acesso a cada planilha continua sendo por
  compartilhamento, não pelo escopo). Volta ao DICON.
- Depois: nada. Renovação silenciosa.
- Manual: **Administração › Conta Google › Conectar**.
- Máquina sem porta local livre: cai no **device‑code** — "acesse
  `google.com/device` e digite `XXXX‑XXXX`" (painel na tela de Administração
  + no log).

## Troubleshooting

| Sintoma | Causa / ação |
|---|---|
| `Apps Script (<acao>): ...` com mensagem de "not authorized"/"permission" | O técnico não tem acesso Leitor à planilha de referência que a função abre (Juntas/Roteiros/Config) — compartilhe a planilha com o grupo de técnicos ou com `@tre-ma.jus.br`. |
| `Token de servico nao configurado` no resultado de um `resultado` | `setupServiceAuth` ainda não foi rodado nesse projeto (ver seção acima). |
| `scripts.run` volta 404/"script not found" | O `deployment_id` em `config/juntas.json` está errado, ou o projeto do Apps Script ainda não foi associado a um projeto GCP padrão. |
| `scripts.run` volta erro de escopo insuficiente | O token do técnico não tem todos os escopos do manifesto — confira `config/ambiente.exemplo.json 
> google_oauth.scopes` e peça pra reconectar (Desconectar → Conectar). |
| "Não conectou" logo após consentir; ou reconecta sempre | App Externo em **"Testing"** (refresh token de 7 dias) — mova para **"Interno"** ou **"Em produção"**. |
| Device‑code não aparece na tela | Ele só é usado quando o navegador local (loopback) falha; o código também sai no log. |
| Trocar de conta | Administração › Conta Google › **Desconectar** → **Conectar**. |

## Onde fica cada coisa (código)

- `src/core/AuthGoogle.ps1` — fluxo OAuth do cliente (config, PKCE loopback,
  device‑code, refresh, DPAPI, header `Get-CabecalhoAuthWebApp`).
- `src/core/AppsScriptApi.ps1` — `Invoke-FuncaoAppsScript`, a única chamada à
  Execution API; usado por `Sync-Juntas`/`Sync-Tecnicos`/`Sync-Roteiros`/
  `Sync-Limiares` (`Juntas.ps1`/`Roteiros.ps1`/`Limiares.ps1`), `Save-Limiares`
  (`Limiares.ps1`) e `Send-Resultado` (`Send-Resultado.ps1`).
- `apps-script/Codigo.gs` — `executar(req)` (dispatcher da Execution API),
  `gravarResultado` (token de serviço + Sheets API v4), `setupServiceAuth`.
- `apps-script/appsscript.json` — `executionApi: {access: DOMAIN}`.
- UI: card "Conta Google" em `viewAdmin` (`MainWindow.xaml`) + funções
  `Invoke-ConectarGoogle` / `Invoke-DesconectarGoogle` / `Update-CardContaGoogle`
  (`src/ui/Janela-Principal.ps1`); login e "Atualizar dados" tratam o erro
  `CONECTAR_GOOGLE`.
- `tools/Extrair-TokenServico.ps1` — imprime o refresh token pra colar no
  `setupServiceAuth`.
- Teste: `tools/Testar-AuthGoogle.ps1` (mock dos endpoints OAuth) e
  `tools/Testar-Envio.ps1` (mock da Execution API).
