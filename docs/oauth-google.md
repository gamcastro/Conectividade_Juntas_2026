# Autenticação Google (OAuth) no cliente DICON

## Por quê

O Web App do Apps Script era publicado com acesso **"Qualquer pessoa" (anônimo)**.
A política do Workspace do TRE‑MA **desabilitou publicar/atualizar Web App anônimo**
→ o `clasp redeploy` fica travado. Saída: publicar como **"Qualquer pessoa do
domínio" (`access: DOMAIN`)** — que **não** é bloqueado — e o cliente DICON manda um
**token OAuth** de uma conta `@tre-ma.jus.br` em toda chamada ao `/exec`.
Consentimento no navegador **1x por computador/usuário Windows**; depois é silencioso
(refresh token, guardado com DPAPI em `%LOCALAPPDATA%\DICON\google-refresh.dat`).

Bônus: o `POST` de resultado (que carrega IP/nome/telefone) passa a ser autenticado
e auditável (coluna `enviado_por` na planilha de Resultados).

## Estado atual

- **Homologação: ligado (v0.6.72).** `config/ambiente.exemplo.json` → `google_oauth`
  com `enabled: true` e a credencial Desktop do projeto GCP **`dicon-oauth`**
  (org `tre-ma.jus.br`, consentimento **Interno**, escopos `openid` +
  `userinfo.email` + **`drive.readonly`** — sem o Drive o `/exec` devolve 401).
  Web App de homologação **reimplantado** (`clasp`, deployment `AKfycbxHMpU…@4`,
  `access: DOMAIN`) — a URL não muda, e uma chamada anônima agora cai na tela de
  login do Google (esperado).
- **Produção: pendente.** `main` ainda em `enabled: false` e Web App anônimo. Na
  próxima promoção `homologacao → main`, repetir o `clasp` de produção
  (deployment `AKfycbyrPcog…`).
- O `client_id`/`client_secret` de app Desktop **não são confidenciais**
  (RFC 8252) e estão liberados no *secret scanning* do GitHub ("used in tests").

## Setup no Google Cloud (uma vez)

1. **Projeto GCP** — pode ser o já associado ao projeto Apps Script (Configurações
   do projeto → Projeto do Google Cloud).
2. **Tela de consentimento OAuth** (APIs e serviços → Tela de permissão OAuth):
   - **"Interno"** (ideal — só usuários `@tre-ma.jus.br`, pula a verificação do
     Google). Exige o projeto estar na **organização Google Cloud do TRE‑MA**.
   - Se não der "Interno": **"Externo"** e mova o status para **"Em produção"**
     (com escopos **não sensíveis** — ver abaixo — não há revisão). App Externo em
     "Testing" emite refresh token que **expira em 7 dias**; tem que estar "Em
     produção".
   - Escopos: `openid`, `.../auth/userinfo.email` **e
     `.../auth/drive.readonly`**. O `/exec` do Apps Script recusa (**401**) um
     token que só tenha `openid`/`email` — precisa de um escopo de API real;
     `drive.readonly` resolve. Em app **Interno** esse escopo sensível **não
     passa pela verificação** do Google. (App Externo: teria de ser verificado —
     outra razão pra preferir Interno.)
3. **Credencial** (APIs e serviços → Credenciais → Criar credenciais → ID do
   cliente OAuth): tipo **"App para computador" (Desktop app)**. Copie o
   **`client_id`** e o **`client_secret`**.
   > Para app instalado, o `client_secret` **não é confidencial** (RFC 8252 /
   > docs do Google). A segurança vem do **PKCE** + redirect em `127.0.0.1`. Pode
   > ser commitado no repositório.

## Ligar no DICON

1. No `config/ambiente.exemplo.json` (branch `homologacao` primeiro, depois `main`),
   preencha o bloco `google_oauth`:
   ```json
   "google_oauth": {
     "enabled": true,
     "client_id": "XXXX.apps.googleusercontent.com",
     "client_secret": "YYYY",
     "scopes": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/drive.readonly"
   }
   ```
   Commit + push. O `Atualizar-DICON.ps1` (v0.6.68+) copia `config/*.exemplo.json`
   para as máquinas; instalação nova pega tudo.
2. **`clasp redeploy`** do canal correspondente (homologação e depois produção) —
   com `access: DOMAIN` **deve passar** (não é o acesso anônimo). Ver
   `apps-script/CLASP.md`.

## Como o técnico conecta

- 1º uso após ligar: abre o navegador → escolhe a conta `@tre-ma.jus.br`
  (já logado no Google corporativo → 2 cliques) → **Permitir**. Volta ao DICON.
- Depois: nada. Renovação silenciosa.
- Manual: **Administração › Conta Google › Conectar**.
- Máquina sem porta local livre (muito travada): cai no **device‑code** —
  "acesse `google.com/device` e digite `XXXX‑XXXX`" (painel na tela de
  Administração + no log).

## Troubleshooting

| Sintoma | Causa / ação |
|---|---|
| Chamadas voltam **401 Não Autorizado** (ou HTML de login) mesmo conectado | O token só tem `openid`/`email`. Confira que `scopes` (em `ambiente.exemplo.json`) e a Tela de consentimento têm **`https://www.googleapis.com/auth/drive.readonly`**, e reconecte (Desconectar → Conectar) pra o token novo carregar o escopo. Se ainda 401, suba pra `https://www.googleapis.com/auth/drive`. |
| `ambiente.exemplo.json` sem o bloco `google_oauth` depois de atualizar | Máquina com `Atualizar-DICON.ps1` anterior à v0.6.68 (não copiava `config/*.exemplo.json`). Rode o atualizador **mais uma vez** (agora o novo já está no disco) ou reinstale pelo `iex`. |
| "Não conectou" logo após consentir; ou reconecta sempre | App Externo em **"Testing"** (refresh token de 7 dias). Mova para **"Em produção"**. |
| `clasp redeploy` ainda dá "ANYONE access disabled" | O `appsscript.json` não está com `DOMAIN`, ou o deployment antigo está fixado numa versão anônima — edite a implantação existente no editor apontando para a nova versão. |
| Device‑code não aparece na tela | Ele só é usado quando o navegador local (loopback) falha; o código também sai no log. |
| Trocar de conta | Administração › Conta Google › **Desconectar** → **Conectar**. |

## Onde fica cada coisa (código)

- `src/core/AuthGoogle.ps1` — todo o fluxo (config, PKCE loopback, device‑code,
  refresh, DPAPI, header).
- Header anexado em `Invoke-RecursoWebApp` (`src/core/Juntas.ps1`), `Save-Limiares`
  (`src/core/Limiares.ps1`), `Send-Resultado` (`src/saida/Send-Resultado.ps1`).
- UI: card "Conta Google" em `viewAdmin` (`MainWindow.xaml`) + funções
  `Invoke-ConectarGoogle` / `Invoke-DesconectarGoogle` / `Update-CardContaGoogle`
  (`src/ui/Janela-Principal.ps1`); login e "Atualizar dados" tratam o erro
  `CONECTAR_GOOGLE`.
- Teste: `tools/Testar-AuthGoogle.ps1` (mock dos endpoints OAuth).
