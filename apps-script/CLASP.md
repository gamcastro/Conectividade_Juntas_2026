# Deploy do Apps Script com clasp

`clasp` (3.4.1) e Node ja estao instalados nesta maquina.

## Estado atual (implantado)

- scriptId:      `1WWMSPY7fRFOO4IPvj0sHHyrIozwNIaegMWzu_s3a3xfkj4YMpjOCa30W`
- deploymentId:  `AKfycbyrPcogTNL_VZUwtgY-gj_J1nx6rXnhsU5l08da7jJ6KTfsIU-3tlHW8ABzVtgKQnvuig`
- URL:           `https://script.google.com/macros/s/AKfycbyrPcogTNL_VZUwtgY-gj_J1nx6rXnhsU5l08da7jJ6KTfsIU-3tlHW8ABzVtgKQnvuig/exec`
- ja configurada em `config/juntas.json`.
- `?recurso=juntas` -> Juntas/locais; `?recurso=tecnicos` -> 8; `?recurso=roteiros` -> 8; `?recurso=limiares` -> limiares de decisao.
- Planilha de config (limiares): `1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww` (aba `Limiares`, criada no 1o salvar).

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
