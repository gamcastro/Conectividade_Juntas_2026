# DICON Web — Plano (ambiente de homologação)

> Console web de coordenação do DICON. Alvo: **homologação** primeiro; produção
> depois de validar.

## 0. Estado

- **Fase 0 — no ar em homologação** ✅ (Painel + Vistorias, só leitura)
  - URL: `https://script.google.com/macros/s/AKfycby4rGyTNWzgl6FxYkdAmnTQpO1zSsmolqJll6psftuH2S-SZQh76s6j2qLWYypZi6wM-w/exec?app=web`
  - Implantação Web App `AKfycby4rG…wM-w` @7 (`clasp create-deployment`, projeto
    de homolog `17BLQ6IOZ…`). A implantação da Execution API que o DICON consome
    (`AKfycbxHMp…` @6) não foi tocada.
  - `apps-script/web/Console.gs`: `verificarAcesso` / `_webExigirAcesso`,
    `_webAbaAcesso` (cria a aba `Acesso` sozinha, semeia o admin bootstrap),
    `_webUniverso`, `_webTestados`, `carregarPainel` (tudo numa chamada).
  - `apps-script/web/Index.html`: SPA vanilla, abas **Painel** e **Vistorias**.
  - `apps-script/Codigo.gs`: `doGet` roteia `?app=web` → `webConsolePagina(e)`.
  - `apps-script/appsscript.json`: `webapp.executeAs` → `USER_ACCESSING`.
  - Redeploy a cada mudança: `clasp push` + `clasp redeploy AKfycby4rG…wM-w`.
- **Fase 1 — no ar em homologação** ✅ (check-in ao vivo)
  - Console: `webCheckin` / `webRegistrarEvento` (via `executar`, token de
    serviço), `carregarAoVivo`, aba **Ao vivo** no `Index.html`. Redeploy @8.
  - DICON desktop (**v0.6.121**, `src/core/EventosWeb.ps1`): `Add-EventoWeb`
    (fila `eventos\pendentes\`, só escreve arquivo), `Send-EventosWebPendentes`
    (flush, no runspace do "Atualizar dados"), `Start-EnvioWebAssincrono`
    (runspace fire-and-forget: heartbeat + flush), `Start/Stop-HeartbeatWeb`
    (timer 5 min). Hooks: `abriu_app` no login, `iniciou_diagnostico` ao chegar
    no passo 3, `transmitiu`, `finalizou`. Toggle `config/envio.json >
    checkin_web` (padrão on); `$Global:ModoTeste` desliga nos testes.
  - **Falta**: o upload do PDF individual para o Drive (mudança no DICON
    desktop) — a coluna PDF fica vazia até isso.
- **Fase 3 — no ar em homologação** ✅ (relatório final)
  - `apps-script/web/RelatorioFinal.gs`: `gerarRelatorioFinal(modo)` monta um
    **HTML → PDF** com `Utilities.newBlob(html,'text/html').getAs('application/pdf')`
    (NÃO `DocumentApp` — ver a trava de escopo abaixo). O PDF volta em **base64**
    e o navegador baixa **e** é arquivado em `DICON/relatorios-finais/` pelo
    token de serviço (`_driveUpload`, best-effort); `pdf_url`/`pdf_id` vão pra
    aba `RelatoriosFinais` e viram a coluna "PDF" do histórico.
    `listarRelatoriosFinais`, `_webTestadosCompleto` (lê `json`).
  - **Visual espelhado do relatório do DICON Desktop** (`src/saida/Export-RelatorioPdf.ps1`):
    cabeçalho JE + brasão (`web/Brasao.gs` = `assets/brasao-republica.jpg` em
    `data:` URI, string constante, sem escopo de Drive), régua navy, faixas
    `#1F4E79`, `th #D9E2F3`, bordas `#BFC9DA`, `table.kv` `#E7EDF6`, layout de 2
    colunas com `<table>` aninhada (sem grid/flex).
  - `Index.html`: aba **Relatório final** (Gerar → baixa o PDF + histórico).
  - Redeploy Web App @13.
- **Fase 2 (GEL pela web) — RETIRADA** (decisão 2026-09-06, Web App **@25**)
  - Chegou a rodar (import do PDF do GEL por pdf.js + conferência das 5 seções +
    upload de fotos + `gerarRelatorioLocal`), mas o `Utilities` HTML→PDF do
    Apps Script não dá paridade visual com o relatório do DICON desktop (é
    retrato, não paisagem; SVG/gráficos instáveis) e `DocumentApp` está barrado
    pela trava de escopo. **A importação do GEL e as fotos ficam SÓ no DICON
    desktop.**
  - Fluxo definido: o técnico transmite pelo DICON desktop (relatório com ou
    sem GEL, sobe pro Drive via `pdf.relatorio` da Fase 4). Se o técnico não
    tem acesso ao GEL web, o **coordenador** abre o **DICON desktop dele**, faz
    login **com o nome do técnico**, "Atualizar dados" (o `Sync-Resultados`
    puxa os resultados transmitidos daquele técnico), vai em **Locais**, anexa
    o formulário do GEL + fotos, "Abrir relatório completo (PDF)" → regenera o
    relatório **completo** e a v0.6.123 sobe pro Drive, sobrescrevendo.
  - Removidos: `apps-script/web/GelWeb.gs`, `apps-script/web/RelatorioLocal.gs`,
    aba **GEL** do `Index.html`, `uploadFotoGel`/`listarFotosGel`/`removerFotoGel`
    de `DriveWeb.gs`, coluna GEL das Vistorias, `sim (web)` do relatório final.
  - **Mantidos** (a Fase 4 usa): token de serviço com `drive.file`
    (`tools/Conectar-DriveServico*.ps1`, `OAUTH_REFRESH_TOKEN` já trocado),
    `_driveGarantirPasta`/`_driveUpload`/`_driveUploadOuAtualiza`/`_resultadoSetPdf`,
    `webUploadPdfRelatorio` (`pdf.relatorio`).
- **Fase 4 — parcial em homologação** 🚧 (polimento)
  - `carregarPainel(forcar)`: corpo pesado (universo × testados) em
    `CacheService` (45 s); o botão **Atualizar** passa `forcar=true`.
  - Aba **Acesso** (só papel `admin`): `listarAcesso` / `salvarAcesso` /
    `removerAcesso` (token de serviço) + tela pra incluir/editar/desativar
    e-mails da allowlist sem abrir a planilha. O admin inicial
    (`WEB_BOOTSTRAP_ADMIN`) não pode ser desativado.
  - **PDF individual → Drive (v0.6.123)**: `executar` ganhou `pdf.relatorio`
    → `webUploadPdfRelatorio` (token de serviço, `drive.file`) sobe o PDF em
    `DICON/relatorios/` (sobrescreve o do mesmo Local, sem duplicar) e grava
    `pdf_url` na linha do Local na aba `Resultados` (`_resultadoSetPdf` cria a
    coluna se faltar) → a coluna **PDF** das Vistorias / do relatório final
    para de ficar vazia. No DICON desktop: `Start-EnvioPdfRelatorioWeb`
    (`EventosWeb.ps1`, runspace próprio, guarda de 9 MB) disparado por
    `Complete-ExportarRelatorio` / `Complete-AbrirRelatorioLocal` quando o
    Local já foi transmitido; toggle `config/envio.json > pdf_web`.
  - Nova ação em `executar` → redeploy das **duas** implantações: Web App
    **@22**, Execution API **@23** (`clasp version` 23).
  - **Falta**: aba-resumo agregada por trigger; retenção da aba `Eventos`.

### ⚠️ Trava de escopo OAuth (vale para Fase 2 também)

O projeto Apps Script é **compartilhado** entre a console (Web App) e a
implantação da **Execution API que o DICON de campo usa** (`AKfycbxHMp…`). A
Execution API exige que o **token do DICON** tenha **todos os escopos do
script** — e o token do DICON só tem `openid userinfo.email spreadsheets
script.external_request` (`config/ambiente.exemplo.json > google_oauth.scopes`).
Se qualquer `.gs` do projeto usar `DriveApp`/`DocumentApp`/Drive API, o manifest
passa a exigir `drive`/`documents` e **o DICON de campo quebra**.

**Regra:** nada no projeto pode exigir escopo além dos 4 acima, enquanto a
console viver no mesmo projeto que a Execution API do DICON.

**Decisão (2026-09-06): opção 1.** Quando o Drive entrar (fotos do GEL, arquivar
o relatório final), o **token de serviço ganha o escopo `drive`** — o George
re-roda `tools/Extrair-TokenServico.ps1` / `setupServiceAuth` com `drive` somado
aos escopos, e as gravações no Drive passam pela **API REST via `UrlFetchApp`**
com esse token. **Nenhum `.gs` chama `DriveApp`/`DocumentApp`** → o manifest
continua mínimo e o DICON de campo (Execution API) não quebra. Sem duplicar
projeto. (Opção 2 descartada: projeto Apps Script separado — isolamento total,
mas exigiria cópias dos leitores `listarJuntas`/`listarRoteiros` e uma segunda
implantação/`doGet`.)

- **Fase 2 — parcial** (GEL pela web; falta só o upload de fotos).
  **Fase 4 — não iniciada**.

## 1. Objetivo

Dar aos coordenadores, pelo navegador e com login corporativo:

- **O que foi feito / está sendo feito / falta fazer** nas vistorias técnicas de
  conectividade, por roteiro / técnico / ZE / município.
- **Ver os relatórios PDF** já produzidos pelos técnicos.
- **Check-in ao vivo**: "James está online" e "James iniciou diagnóstico em
  <Local>".
- **Importar o formulário do GEL** (PDF) e **as fotos** pela própria console,
  com extração dos campos e formulário de conferência — no mesmo espírito do
  DICON desktop.
- **Relatório final consolidado** por botão, quando (ou antes de) todos os
  locais estarem testados.
- **Acesso controlado** por uma lista de administradores numa planilha.

### Fora de escopo (v1)

- Substituir a tela de **Administração** do DICON desktop (limiares, servidor
  iperf3, semáforo, sugestões de motivo). Continua no desktop.
- **GPS ao vivo** do técnico (posição no mapa em tempo real). A console mostra o
  **Local do roteiro** em que ele está; coordenada precisa vem do GEL, depois.
- **Juntar** os PDFs individuais num único arquivo (Apps Script não faz merge de
  PDF nativo — o relatório final **linka** cada PDF).
- Editar Locais / roteiros pela web.

## 2. Arquitetura

| Camada | Escolha | Motivo |
|---|---|---|
| App | **Apps Script Web App** (`HtmlService`), no projeto Apps Script de **homologação** (`scriptId 17BLQ6IOZ6BVf4KUyfNJtQa7klssUOputNqIwen_GwQ1ZK5S-f14g1ehh`) | zero hospedagem, HTTPS, login corporativo de graça, mesma stack do backend do DICON |
| Implantação | **nova implantação "Web App"**, separada da implantação da Execution API que o DICON usa | não mexe no que o DICON consome; o coordenador acessa por uma URL própria |
| Front-end | `HtmlService` + JS simples; libs de CDN quando precisar (pdf.js) | dispensa build; o Apps Script permite `<script src>` externo |
| Extração do GEL | **pdf.js** (`pdfjs-dist`, versão fixa, do cdnjs) rodando **no navegador**, em modo main-thread (sem Web Worker) | acurácia equivalente ao PdfPig para PDF digital; nada roda no servidor |
| Backend | funções novas em `apps-script/Codigo.gs`, chamadas por `google.script.run` (da página) e por `executar`/`doPost` (do DICON desktop) | reaproveita o transporte e o `Codigo.gs` já existentes |
| Dados | planilha **`DICON — Resultados (Homologação)`** (`1aihOABaGSnHNIP5BHisR-iI1-OpQWHALLt5jvsUzpWE`) + abas novas; pasta no **Google Drive** de homolog | tudo já vive no Google |
| Auth | Web App = "qualquer pessoa de `tre-ma.jus.br`" + **allowlist numa aba** da planilha, conferida **no servidor** | "escolher quais contas" sem depender do admin do Workspace |

### Repositório

**Mesmo repo** (`Conectividade_Juntas_2026`), pasta **`apps-script/web/`** com os
`.html` do `HtmlService` e os `.gs` da console, no **mesmo projeto clasp** de
homolog. Fácil separar depois se a console crescer. Redeploy manual (clasp), como
todo o resto do Apps Script — documentar no `apps-script/CLASP.md`.

## 3. Modelo de dados (abas novas na planilha de homolog)

| Aba | Colunas | Papel |
|---|---|---|
| **`Acesso`** | `email` · `papel` (`admin`\|`leitura`) · `ativo` (sim/não) · `obs` | allowlist de quem entra na console |
| **`Presenca`** | `tecnico` · `email` · `ultimo_checkin` · `versao_dicon` · `roteiro` · `maquina` · `atividade_atual` · `local_atual` | 1 linha por técnico (upsert) — o "online" sai daqui |
| **`Eventos`** | `id_evento` · `hora_cliente` · `hora_servidor` · `tecnico` · `tipo` · `local_id` · `zona` · `municipio` · `tipo_local` · `roteiro` · `detalhe` | linha do tempo (append); `tipo` ∈ `abriu_app` / `iniciou_diagnostico` / `rodou_checagem` / `salvou` / `transmitiu` / `finalizou` / `abandonou` |
| **`GEL`** | `local_id` · `pasta_drive_id` · `pdf_gel_id` · `n_fotos` · `secoes_json` · `por` (email) · `quando` | índice do que foi anexado **pela web** |
| **`RelatoriosFinais`** | `gerado_em` · `por` · `modo` · `cobertura_pct` · `doc_id` · `pdf_id` | histórico das gerações do relatório final |

### Colunas novas na aba `Resultados`

- `pdf_drive_id` / `pdf_url` — id/link do PDF individual **enviado pelo DICON**
  (mudança no desktop, item 4).
- `gel_via_web` (sim/não) e `gel_atualizado_em` — quando o GEL veio pela console.

### Pasta no Drive (homolog)

**Shared Drive da organização** (decisão 3), com a árvore:

```
DICON-HOMOLOG/
  relatorios/               PDFs individuais (upload do DICON)
  gel/<local_id>/           PDF do GEL + fotos importadas pela console
  relatorios-finais/        Doc + PDF do relatório consolidado
```

*Falta o ID do Shared Drive.* Escritas exigem que a allowlist tenha **acesso de
colaborador** nesse Shared Drive.

## 4. Mudanças no DICON desktop (homologação)

Todas **best-effort, não-bloqueantes, offline-first** — nada disso pode travar a
tela nem fazer um diagnóstico falhar.

1. **Fila de eventos** (`resultados\pendentes\` → padrão análogo `eventos\pendentes\`):
   grava um evento localmente e envia na próxima conexão.
   - `abriu_app` no login.
   - `iniciou_diagnostico` **ao chegar no passo 3** (meios de conexão) do
     assistente, com o Local escolhido.
   - `rodou_checagem` (lan/wifi/celular), `salvou`, `transmitiu`, `finalizou`,
     `abandonou` (Sair do assistente sem testar).
2. **Heartbeat**: um timer (~5 min) enquanto a janela está aberta **e com
   internet** → ação `checkin`.
3. **Upload do PDF**: no "Transmitir" (ou num botão "Enviar relatório"), sobe o
   PDF já gerado (`relatorios\...pdf`) para o Drive e grava `pdf_drive_id` na
   linha do resultado. O PDF já vem com as fotos embutidas.
4. Idempotência: cada evento com `id_evento` gerado no cliente (dedupe no flush).

Bump de versão do DICON quando isso entrar (ex.: `v0.6.121`), promovido a produção
depois.

## 5. Backend — funções novas em `Codigo.gs`

Todas começam com **guarda de acesso** (`_exigirAcesso()` — ver item 8).

| Função | Chamada por | O que faz |
|---|---|---|
| `checkin(req)` | DICON | upsert na `Presenca` |
| `registrarEvento(req)` | DICON | append `Eventos` (dedupe por `id_evento`) + atualiza `Presenca.atividade_atual` / `local_atual` |
| `listarPainel()` | console | agrega **universo** (Juntas/Roteiros, planilhas `11MqlYAJ…` / `1EQ32sRX…`) × **testados** (`Resultados`, último por `local_id`) → cobertura por ZE / município / roteiro / técnico + lista de pendentes |
| `listarPresenca()` | console | linhas da `Presenca` + flag "online" (`ultimo_checkin` < 10 min) |
| `listarEventos(desde)` | console | feed da `Eventos`, ordenado por `hora_cliente` |
| `listarVistorias(filtros)` | console | tabela de **todos** os Locais do universo com status (não testado / medido-ou-veredito / GEL sim-não) + `pdf_url` |
| `salvarGelWeb(req)` | console | valida a allowlist, cria a pasta `gel/<local_id>/`, grava `secoes_json` na aba `GEL`, marca `Resultados.gel_via_web` |
| `uploadFotoGel(local_id, base64, nome)` | console | grava a imagem (já redimensionada no cliente) em `gel/<local_id>/foto-NN.jpg`; devolve o id |
| `uploadPdfRelatorio(local_id, base64, nome)` | DICON | grava em `relatorios/`; grava `pdf_drive_id` na linha |
| `gerarRelatorioFinal(modo)` | console | monta um **Google Doc** consolidado → `getAs('application/pdf')` → salva em `relatorios-finais/` → registra em `RelatoriosFinais` → devolve o link. Funciona a qualquer cobertura (parcial) ou só 100% |
| `verificarAcesso()` | console | devolve `{email, papel}` do visitante a partir da aba `Acesso` |

Cotas: com poucos coordenadores e ~dezenas de eventos/dia, folgado. `listarPainel`
lê 3 planilhas — usar `CacheService` (TTL curto) e/ou uma **aba-resumo** agregada
por um trigger periódico.

## 6. Front-end — telas (`HtmlService`)

Ao abrir: login Google implícito → `verificarAcesso()` → sem acesso ⇒ tela
"sem permissão".

1. **Painel** (home) — cobertura geral (X de Y locais), barras por roteiro /
   técnico / ZE, lista dos pendentes, atalho para o relatório final.
2. **Ao vivo** — card por técnico (online / visto há X, atividade atual, Local do
   roteiro) + **feed de eventos** ("10:12 James iniciou diagnóstico em ESCOLA X ·
   ZE 43 Monção · há 3 min"). Detecção de "travado" ("iniciou há 1h40 e não
   transmitiu").
3. **Vistorias** — tabela de **todos** os Locais (o universo), status, filtros
   (ZE / município / técnico / roteiro), **link para o PDF individual**.
4. **GEL (por Local)** —
   a. upload do PDF do GEL → **pdf.js extrai no navegador** →
   b. formulário das **5 seções** (Coordenadas / Tipo do local / Infraestrutura /
      Elétrica / Suporte ao link) preenchido, editável — a **conferência** →
   c. "Registrar" → `salvarGelWeb`;
   d. **upload de fotos**: `<input type=file multiple accept="image/*">` →
      redimensiona no `<canvas>` (1600 px / q80) → `uploadFotoGel` uma a uma;
      galeria com remover.
5. **Relatório final** — **só pelo botão** "Gerar" (se < 100%, mostra "faltam N
   locais" e permite **parcial**) → `gerarRelatorioFinal` → link do PDF +
   histórico. Conteúdo no modo `medicao`: por Local, **medições + meio sugerido +
   cabo de rede + observações do técnico + GEL sim/não + link do PDF**; cobertura
   por ZE/município/técnico; **sem** KPIs de viabilidade.
6. **Acesso** (só papel `admin`) — edição da aba `Acesso` pela tela, ou link
   direto para a planilha.

## 7. Extração do GEL no navegador (pdf.js)

- Carregar `pdfjs-dist` **numa versão fixa** do cdnjs; `GlobalWorkerOptions` em
  modo main-thread (`disableWorker`) para não depender de Web Worker no iframe
  sandboxado.
- `getDocument({data})` → por página `getTextContent()` → **reconstruir a ordem
  de leitura** pelas posições (y desc, x asc) → string normalizada **sem acento**.
- **Port do `ConvertFrom-VistoriaGel`** (PowerShell → JS): mesmos marcadores e
  regex — a resposta **antes** de `R. :`, o rótulo `Coordenadas:` **depois** do
  valor, captura para no primeiro `?`. As 5 seções, iguais ao desktop.
- **Calibração**: casos de teste **lado a lado** (saída do extrator desktop ×
  saída da web) com os **mesmos PDFs de GEL reais**. Reservar tempo para isso —
  é o item mais arriscado do plano.
- **Fallback**: se a extração vier vazia ou parcial, o formulário abre em branco
  para preenchimento manual — nunca trava.

## 8. Autenticação / acesso

- Publicar o Web App de homolog como **"Qualquer pessoa de `tre-ma.jus.br`"**,
  **executar como o usuário que acessa** (para obter `Session.getActiveUser().getEmail()`).
- Aba **`Acesso`** na planilha de homolog: `email` · `papel` · `ativo`.
- `_exigirAcesso(papelMinimo)` no início de **toda** função de backend e no
  carregamento da página. Cliente só esconde botão — **a regra é no servidor**.
- **Sem token de serviço** (decisão 2). A console lê os dados **como o próprio
  usuário logado** — por isso os membros da allowlist recebem **leitor** nas
  planilhas `Resultados (Homologação)`, `Informações Juntas Especiais` e
  `Roteiros`. As escritas (GEL, fotos, relatório final) vão para o **Shared
  Drive** e para abas da planilha de homolog, onde a allowlist precisa de
  **editor**.
- Gerenciar acesso = editar a aba `Acesso` (ou, quando quiser "oficial", pedir ao
  admin do Workspace **uma vez** um Grupo `dicon-web-*@tre-ma.jus.br` e trocar a
  checagem para `GroupsApp.hasUser` — e compartilhar as planilhas/Shared Drive
  com o Grupo em vez de e-mail a e-mail).

## 9. Deploy (homologação)

1. `apps-script/web/` no repo, no projeto clasp de homolog (`17BLQ6IOZ…`).
2. `clasp push` → o projeto de homolog passa a ter os `.gs`/`.html` novos.
3. `clasp create-deployment` de uma **implantação nova** do tipo **Web App**
   ("DICON Web — homolog") — **não** mexe na implantação `AKfycbxHMp…` que o DICON
   consome pela Execution API.
4. A URL do Web App fica com a coordenação. Nada muda em `config/juntas.json`.
5. Redeploy manual a cada mudança (clasp) — registrar o passo no `CLASP.md`.

## 10. Fases de entrega

| Fase | Entrega | Depende de |
|---|---|---|
| **0 — fundação** | abas novas + `verificarAcesso` + `listarPainel` + telas **Painel** e **Vistorias** (só leitura) | nada (dado já existe) — **já entrega valor** |
| **1 — check-in** | DICON desktop: eventos + heartbeat + fila local + upload do PDF · backend `checkin`/`registrarEvento`/`uploadPdfRelatorio` · tela **Ao vivo** | bump de versão do DICON |
| **2 — GEL web** | pdf.js + port do extrator + calibração · formulário de conferência · `salvarGelWeb` · upload de fotos com resize | Fase 0 |
| **3 — relatório final** | `gerarRelatorioFinal` (Doc→PDF, modo `medicao`) + tela + **botão manual** (parcial ou 100%) | links dos PDFs individuais = upload da Fase 1 |
| **4 — polimento** | edição da aba `Acesso` pela UI · `CacheService` · aba-resumo agregada · retenção da `Eventos` (90 dias → arquivo) | — |

## 11. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| pdf.js Web Worker no iframe sandbox do Apps Script | modo main-thread (`disableWorker`) |
| Extração do GEL na web ≠ acurácia do desktop | port fiel dos regex + **calibração lado a lado** com PDFs reais + fallback manual |
| Offline-first: eventos/PDF só sobem com internet | fila local + flush na conexão; console rotula "recebido em lote" |
| Cotas do Apps Script (6 min, execuções simultâneas) | `CacheService`, aba-resumo periódica, poucos usuários |
| Sem merge nativo de PDF | relatório final **linka** os individuais, não junta |
| "100%" só faz sentido com o universo congelado | a console mostra a **data de referência** do universo |
| Monitoramento de servidores (check-in) | transparência com o técnico; só eventos de trabalho; retenção curta; **aval do dono do processo** (RH/gestão) |
| Homolog pode não ter token de serviço | rodar "como o usuário" + leitor nas planilhas de referência para a allowlist |
| Foto de celular grande estoura o `google.script.run` | **resize obrigatório no cliente** antes do upload |

## 12. Dependências de terceiros

- **Admin do Google Workspace**: **não obrigatório** para homolog se usar
  allowlist em planilha + "executar como o usuário". Só entra se você quiser um
  Grupo do Google ou a Admin SDK.
- **Drive**: uma pasta (conta do George ou Shared Drive da coordenação).
- **Gestão/RH**: validar o check-in de atividade dos técnicos antes de ligar a
  Fase 1.

## 13. Testes

- **Backend**: funções puras exercitadas por um harness manual / `clasp run`;
  para o extrator do GEL, **casos lado a lado** (desktop × web) com os PDFs de
  GEL reais.
- **Fluxo manual em homolog**: allowlist (dentro/fora), Painel, Ao vivo
  (simulando eventos), GEL (subir um PDF real + fotos), relatório final parcial e
  a 100%.
- **DICON desktop**: `Testar-Fluxo.ps1` ganha checagens da fila de eventos e do
  upload do PDF (best-effort, não quebra offline).

## 14. Decisões tomadas (2026-09-05)

1. **`iniciou_diagnostico` é reportado ao chegar no passo 3** (meios de conexão)
   — não ao abrir o assistente. Evita registrar quem só abriu e saiu.
2. **Sem token de serviço.** A console **executa "como o usuário que acessa"**;
   os membros da allowlist recebem acesso de **leitor** nas planilhas de
   referência (`Resultados (Homologação)`, `Informações Juntas Especiais`,
   `Roteiros`).
3. **Shared Drive da organização** guarda as pastas
   (`relatorios/`, `gel/<local_id>/`, `relatorios-finais/`). *Falta o ID do
   Shared Drive.*
4. **Relatório final: só pelo botão manual.** Sem trigger automático no 100%.
5. **Modo `medicao`.** O relatório final é **medições + sugestão de conexão**
   (download/latência/perda por meio, meio sugerido, cabo de rede, observações do
   técnico, GEL anexado) — **sem** KPIs de viável/ressalva/inviável.
6. **(2026-09-06) Drive = opção 1** (token de serviço ganha `drive`; sem projeto
   separado). Ver "Trava de escopo OAuth" acima.
7. **(2026-09-06) Fase 2 primeiro, fotos por último.** O import do GEL + a
   conferência + o `salvarGelWeb` (só Sheets) entram antes; o upload de fotos
   espera o `drive` no token de serviço.

### O que ainda falta para arrancar a Fase 0

- **ID do Shared Drive** da coordenação.
- Compartilhar as **3 planilhas de referência** como *leitor* com os e-mails da
  allowlist (ou com um Grupo, se preferir).
