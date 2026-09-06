# DICON Web — Plano (ambiente de homologação)

> Console web de coordenação do DICON. Alvo: **homologação** primeiro; produção
> depois de validar.

## 0. Estado

- **Fase 0 — código escrito, não implantado** (branch `homologacao`):
  - `apps-script/web/Console.gs` — `verificarAcesso` / `_webExigirAcesso`,
    `_webAbaAcesso` (cria a aba `Acesso` sozinha, semeia o admin bootstrap),
    `_webUniverso` (união dos `juntas_ids` dos roteiros), `_webTestados` (último
    resultado por `local_id` da aba `Resultados`), `carregarPainel` (acesso +
    resumo + agregados por roteiro/técnico/ZE/município + lista de vistorias,
    numa chamada só).
  - `apps-script/web/Index.html` — SPA de uma página: resumo de cobertura + abas
    **Painel** (4 blocos agregados) e **Vistorias** (tabela filtrável por texto /
    roteiro / status, com link do PDF quando houver). Vanilla JS.
  - `apps-script/Codigo.gs` — `doGet` roteia `?app=web` → `webConsolePagina(e)`.
  - `apps-script/appsscript.json` — `webapp.executeAs` → `USER_ACCESSING`
    (para a console enxergar o e-mail do visitante). O Web App legado não é mais
    usado; a Execution API que o DICON consome não usa `webapp.*`.
- Falta implantar: `clasp push` no projeto de homolog + `clasp create-deployment`
  de uma implantação **Web App** nova ("DICON Web — homolog"), com a URL entregue
  à coordenação. Nada muda em `config/juntas.json`.
- Fases 1–4: não iniciadas.

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

### O que ainda falta para arrancar a Fase 0

- **ID do Shared Drive** da coordenação.
- Compartilhar as **3 planilhas de referência** como *leitor* com os e-mails da
  allowlist (ou com um Grupo, se preferir).
