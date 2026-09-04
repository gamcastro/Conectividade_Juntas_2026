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

## Config extra

- `?recurso=juntas` -> Juntas/locais; `?recurso=tecnicos`; `?recurso=roteiros`; `?recurso=limiares`.
- Planilha de config (limiares): `1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww` (aba `Limiares`, celula A2 = JSON aninhado, criada no 1o salvar).

## Acesso do Web App: DOMAIN (v0.6.69+)

O `appsscript.json` esta com `"access": "DOMAIN"` ("Qualquer pessoa do dominio")
em vez de `ANYONE_ANONYMOUS` -> o `clasp redeploy` **nao** cai mais no erro
"ANYONE access has been disabled by your domain administrator" (a politica do
Workspace so barra o anonimo). O cliente DICON autentica com OAuth quando
`config/ambiente.json > google_oauth.enabled` (ver `docs/oauth-google.md`).
Se uma implantacao antiga estiver fixada numa versao anonima, edite-a no editor
(Implantar > Gerenciar implantacoes > lapis > Versao: nova) apontando para a
versao nova com `access: DOMAIN`.

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
