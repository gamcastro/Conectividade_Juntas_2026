# Deploy do Apps Script com clasp

`clasp` (3.4.1) e Node ja estao instalados nesta maquina.

## Dois ambientes (mesmo Codigo.gs, projetos separados)

Cada projeto escolhe a planilha de Resultados pela Script Property
`PLANILHA_RESULTADOS_ID` (funcao `_idResultados()`; sem a propriedade, cai no
`PLANILHA_RESULTADOS_ID_PADRAO` = a de producao). Juntas/roteiros/limiares sao
os mesmos (planilhas compartilhadas) nos dois.

### PRODUCAO (branch `main`)
- scriptId:      `1WWMSPY7fRFOO4IPvj0sHHyrIozwNIaegMWzu_s3a3xfkj4YMpjOCa30W`
- deploymentId:  `AKfycbyrPcogTNL_VZUwtgY-gj_J1nx6rXnhsU5l08da7jJ6KTfsIU-3tlHW8ABzVtgKQnvuig`
- URL:           `https://script.google.com/macros/s/AKfycbyrPcogTNL_VZUwtgY-gj_J1nx6rXnhsU5l08da7jJ6KTfsIU-3tlHW8ABzVtgKQnvuig/exec`
- Planilha Resultados: `1FnuGm-4sZHXamsK6WtHBKOIUlIsFobhrq6rhpBTrswk` (aba `Resultados`).
- clasp: `.clasp.prod.json` (raiz, gitignored).

### HOMOLOGACAO (branch `homologacao`)
- scriptId:      `17BLQ6IOZ6BVf4KUyfNJtQa7klssUOputNqIwen_GwQ1ZK5S-f14g1ehh`
- deploymentId:  `AKfycbxHMpUwQuDH1SwRiLersK1Qbk3x90Xpu76zxnPl12Upthotd3UiaTd_eOPQ01FF2PBk`
- URL:           `https://script.google.com/macros/s/AKfycbxHMpUwQuDH1SwRiLersK1Qbk3x90Xpu76zxnPl12Upthotd3UiaTd_eOPQ01FF2PBk/exec`
  (em `setup/Baixar-e-Instalar.ps1` `$EndpointPadrao` da branch `homologacao`).
- Planilha Resultados: `1aihOABaGSnHNIP5BHisR-iI1-OpQWHALLt5jvsUzpWE`
  ("DICON - Resultados (Homologacao)", drive SEASU/ACOES/JUNTAS ESPECIAIS).
  Script Property `PLANILHA_RESULTADOS_ID` ja setada nesse valor.
- clasp: `.clasp.homolog.json` (raiz, gitignored).

### Redeploy do HOMOLOGACAO (mantendo a URL)

O `clasp push` falha em `D:\...` com "Content directory is a symlink" (bug do
clasp 3.4 no Windows). Rodar de uma pasta limpa no `C:`:

    Copy-Item .clasp.prod.json .clasp.json -Force     # deixa o repo em producao
    cp apps-script\Codigo.gs apps-script\appsscript.json  $env:USERPROFILE\dicon-clasp-homolog\
    cd $env:USERPROFILE\dicon-clasp-homolog
    clasp push -f
    clasp create-deployment -i AKfycbxHMpUwQuDH1SwRiLersK1Qbk3x90Xpu76zxnPl12Upthotd3UiaTd_eOPQ01FF2PBk -d "homolog vN"

(a pasta `~/dicon-clasp-homolog` tem um `.clasp.json` com o scriptId de homolog
e `rootDir` vazio.)

## DICON Web (console de coordenação) — homologação

Vive no **mesmo projeto Apps Script de homolog** (`17BLQ6IOZ…`), pasta
`apps-script/web/` (`Console.gs`, `DriveWeb.gs`, `RelatorioFinal.gs`,
`Brasao.gs`, `Index.html`). Ver `docs/dicon-web-plano.md`.

| ambiente | Web App da console (`?app=web`) | Execution API do DICON de campo |
|---|---|---|
| **homolog** | `AKfycby4rGyTNWzgl6FxYkdAmnTQpO1zSsmolqJll6psftuH2S-SZQh76s6j2qLWYypZi6wM-w` (@39, v0.6.137 Mapa) | `AKfycbxHMpUwQuDH1SwRiLersK1Qbk3x90Xpu76zxnPl12Upthotd3UiaTd_eOPQ01FF2PBk` (@33) |
| **prod** (2026-09-06) | `AKfycbylhIAahOf0coAHwpOH2OCMbySmfeZR1feT-JFG5aw69GGrtRWYAnxtcL4b3carWYNy0w` (@16) | `AKfycbya1hdu7dgLzXd8U2Totm8cffCtiAnIjJptppe7AuxfvbuHhkNGOAXlCa90QCE_-HOApQ` (@16, `clasp version` 16) |

- URL da console = `.../macros/s/<Web App deploymentId>/exec?app=web` (`doGet`
  roteia `?app=web` → `webConsolePagina`).
- A implantação **legada** `/exec` anônima de prod (`AKfycbyrPcog…` @12) fica
  **congelada** — nunca é tocada.
- **`DICON_DRIVE_ROOT`** (Script Property, só em prod): pasta `DICON` de produção
  no Shared Drive `= 11fTYm2KdDWR5BZaq6igCswSiWlsgctc_`. Sem a property (homolog)
  → cai na pasta antiga (`1ZaV3-…`, renomeada para `DICON-HOMOLOG`).

Redeploy da console (mantém a URL), da pasta `~/dicon-clasp-homolog`
(ou `~/dicon-clasp-prod` p/ produção):

    cp apps-script\web\*.gs apps-script\web\*.html  $env:USERPROFILE\dicon-clasp-homolog\web\
    cd $env:USERPROFILE\dicon-clasp-homolog
    clasp push -f
    clasp redeploy AKfycby4rGyTNWzgl6FxYkdAmnTQpO1zSsmolqJll6psftuH2S-SZQh76s6j2qLWYypZi6wM-w -d "DICON Web homolog vN"

### ⚠️ Ação nova em `executar` → redeploy das DUAS implantações

Funções chamadas por **`google.script.run`** (a página da console:
`carregarPainel`, `carregarAoVivo`, `gerarRelatorioFinal`, `listarAcesso`,
`salvarAcesso`, …) só precisam do redeploy do **Web App** acima.

Mas toda **nova `acao` dentro de `executar`** (`Codigo.gs`) que o DICON de campo
chame pela Execution API (ex.: `checkin`, `evento`, `resultados.listar`,
`pdf.relatorio`, `gel.enviar`, `gel.obter`) **exige `clasp version` +
`clasp redeploy AKfycbxHMp… -V <n>` também** — senão a implantação congela sem a
ação e responde `{erro:'acao desconhecida: …'}`, e o DICON nunca tira os itens da
fila. Já mordeu com `resultados.listar` e com `checkin`/`evento`.
O par `gel.enviar` / `gel.obter` (v0.6.125, `apps-script/web/GelWeb.gs` — sync do
formulário do GEL + fotos: aba `GEL` da planilha de Resultados + Drive da
coordenação em `vistoria-gel/<local_id>/`) foi adicionado nesse mesmo passo:
`clasp push -f` copia o `GelWeb.gs` novo, e as DUAS implantações precisam do
redeploy.

    clasp push -f
    clasp redeploy AKfycby4rG…wM-w -d "DICON Web homolog vN"        # Web App
    clasp version "vN <resumo>"                                     # cria a versao (imprime o numero)
    clasp redeploy AKfycbxHMpUwQuDH1SwRiLersK1Qbk3x90Xpu76zxnPl12Upthotd3UiaTd_eOPQ01FF2PBk -V <numero> -d "vN"

### Aba "Mapa" da console (v0.6.132 pinos · v0.6.133 choropleth) — só Web App

`carregarMapa` / `carregarMalhaMA` (`apps-script/web/Console.gs` +
`apps-script/web/MalhaMA.gs`, malha municipal do IBGE embutida) são chamadas por
**`google.script.run`** → só o redeploy do **Web App** (`clasp push -f` +
`clasp redeploy AKfycby4rG…wM-w -d "…"`), NÃO mexe em `executar`. A v0.6.133
acrescentou o choropleth por município (de-para nome→código IBGE por nome
normalizado; nomes sem match voltam em `municipios_sem_codigo`).

**Setup GCP (uma vez, o George faz)** — sem isto a aba mostra o aviso "chave não
configurada" e a lista de pendentes, o resto da console segue normal:
1. Projeto `dicon-oauth` no GCP → "APIs e serviços" → ativar **Maps JavaScript API**
   (exige uma conta de faturamento anexada ao projeto; pôr um teto de orçamento).
2. "Credenciais" → criar **Chave de API**; restringir por **referenciador HTTP**:
   `*.googleusercontent.com/*` e `script.google.com/*` (o Web App roda em iframe
   `*.googleusercontent.com`); restringir também a API à "Maps JavaScript API".
3. Apps Script (projeto de homolog `17BLQ6IO…`) → **Configurações do projeto** →
   **Propriedades do script** → adicionar `GOOGLE_MAPS_JS_KEY` = a chave.
   (Em produção, repetir a property no projeto `1WWMSPY7…` quando promover.)

A malha (`MalhaMA.gs`, ~135 KB) é servida por `carregarMalhaMA()` como string —
`clasp push -f` já a leva. Regenerada por `scratchpad/gen-malha-gs.mjs` a partir
da API de malhas do IBGE (`.../api/v3/malhas/estados/21`, domínio público).

## Config extra

- `?recurso=juntas` -> Juntas/locais; `?recurso=tecnicos`; `?recurso=roteiros`; `?recurso=limiares`.
- Planilha de config (limiares): `1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww` (aba `Limiares`, celula A2 = JSON aninhado, criada no 1o salvar).

## Acesso do Web App: DOMAIN (v0.6.69+) -- so URL /exec, nao usado pelo cliente

O `appsscript.json` esta com `"access": "DOMAIN"` ("Qualquer pessoa do dominio")
em vez de `ANYONE_ANONYMOUS` -> o `clasp redeploy` **nao** cai mais no erro
"ANYONE access has been disabled by your domain administrator" (a politica do
Workspace so barra o anonimo). MAS: testado ao vivo que um Web App `DOMAIN` na
URL `/exec` **ignora** um `Authorization: Bearer` (so aceita sessao de
navegador) -- por isso o cliente DICON nao usa mais esse caminho.

## Transporte real: Execution API + Executavel de API (v0.6.73+)

`appsscript.json` tem tambem `"executionApi": {"access": "DOMAIN"}`, ao lado do
`webapp`. O `clasp push` + `create-deployment`/`redeploy` de sempre ja leva os
dois -- a MESMA implantacao (mesmo deploymentId/URL) passa a responder tanto
`/exec` (legado, nao usado) quanto `scripts.run` da Execution API.

**Setup adicional, uma vez por ambiente** (antes do primeiro `clasp push` deste
formato): no editor do Apps Script, Configuracoes do projeto > "Projeto do
Google Cloud" > Alterar projeto > numero do projeto GCP `dicon-oauth` (padrao,
com a Apps Script API ativada -- NAO o "Padrao" oculto que cada script ganha
sozinho). Ver `docs/oauth-google.md` para o passo a passo completo (inclui o
token de servico do `gravarResultado`).

Se uma implantacao antiga estiver fixada numa versao anonima do Web App, edite-a
no editor (Implantar > Gerenciar implantacoes > lapis > Versao: nova).

## PIN do admin (para "Salvar limiares")

O Web App valida o PIN contra a Script Property `ADMIN_PIN_SHA256`. Configure 1x:

1. `tools\Definir-PIN-Admin.ps1` (gera `config/admin.json` e imprime o hash).
2. No editor do Apps Script: engrenagem **Configuracoes do projeto** >
   **Propriedades do script** > **Adicionar propriedade do script**:
   `ADMIN_PIN_SHA256` = `<hash impresso>`. (Nao precisa reimplantar.)

Redeploy mantendo a mesma URL:

    clasp push -f
    clasp redeploy AKfycbyrPcogTNL_VZUwtgY-gj_J1nx6rXnhsU5l08da7jJ6KTfsIU-3tlHW8ABzVtgKQnvuig -d "vN"

## Divisao de tarefas

| Passo | Quem |
|---|---|
| 1. Ativar a Apps Script API (navegador) | voce |
| 2. `clasp login` (OAuth no navegador) | voce, uma vez |
| 3. Criar o projeto / obter o scriptId | voce (ou eu, se o login servir) |
| 4. `clasp push` / `clasp deploy` / ler URL | eu, pelo terminal |
| 5. Colar a URL em `config/juntas.json` | eu |

Depois do passo 2, as credenciais ficam em `~/.clasprc.json` (fora do repo) e
eu consigo rodar push/deploy sem interacao.

## Passo 1 - Ativar a API (uma vez por conta)

Abra e ligue a chave:

    https://script.google.com/home/usersettings

("API do Google Apps Script" = Ativado).

## Passo 2 - Login (uma vez)

Na raiz do projeto:

    clasp login

Abre o navegador; entre com a conta que tem acesso a planilha
*Informacoes Juntas Especiais*. Ao final: "You are logged in as ...".

Confirma com:

    clasp show-authorized-user

## Passo 3 - Projeto

### Opcao A - criar novo pelo clasp (raiz do repo)

    clasp create --type webapp --title "Conectividade Juntas 2026 - Web App" --rootDir apps-script

Isso grava `.clasp.json` (na raiz) e pode sobrescrever `apps-script/appsscript.json`
-> se sobrescrever, restaure a versao deste repo (bloco `webapp`) antes do push.

### Opcao B - projeto ja criado no navegador

Pegue o scriptId da URL do editor
(`script.google.com/d/<SCRIPT_ID>/edit`) e crie `.clasp.json` na raiz:

    { "scriptId": "<SCRIPT_ID>", "rootDir": "apps-script" }

## Passo 4 - Push + deploy

    clasp push -f
    clasp deploy -d "v1"
    clasp deployments

A URL do Web App e:

    https://script.google.com/macros/s/<DEPLOYMENT_ID>/exec

Teste no navegador: `.../exec?recurso=juntas` deve devolver JSON.

## Passo 5 - Configurar a ferramenta

Copie `config/juntas.exemplo.json` para `config/juntas.json` e cole a URL em
`endpoint`. Depois, na GUI, botao **Atualizar lista**.

## Redeploy (proximas versoes)

    clasp push -f
    clasp redeploy <DEPLOYMENT_ID> -d "v2"

Mantem a mesma URL. `clasp deploy` sem `-i` cria uma URL nova a cada vez.

## Ver logs de execucao

    clasp logs
