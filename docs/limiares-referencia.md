# Referência de limiares

> **Onde ficam:** planilha Google de configuração
> (`1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww`, aba `Limiares`, célula **A2**
> = JSON), editável pelo **administrador** na tela de Administração do app. O Web
> App expõe `?recurso=limiares`; a ferramenta cacheia em `data/limiares.json`. Se
> a aba ainda não existe, valem os padrões (`config/limiares.exemplo.json`).
>
> **Salvar** exige o PIN do admin. Pré-requisito: no editor do Apps Script,
> engrenagem *Configurações do projeto* → *Propriedades do script* → adicionar
> `ADMIN_PIN_SHA256` com o hash impresso por `tools/Definir-PIN-Admin.ps1`.
>
> ⚠️ **v0.6.67 mudou o formato dos limiares** (plano → aninhado por meio ×
> cenário). O `apps-script/Codigo.gs` foi atualizado no repositório mas **ainda
> não foi reimplantado**. Até o admin rodar `clasp push` + nova implantação, o
> `data/limiares.json` / `config/limiares.json` local é a fonte da verdade — a
> tela de Administração salva local e o app funciona normalmente; só o
> sync/save online fica indisponível.

## Modelo de avaliação

Cada métrica é classificada em `viavel`, `ressalva` ou `inviavel`. A
classificação final de cada **medição** (meio) é o pior caso entre as métricas
daquele meio; o veredito do **local** é o do meio recomendado.

| Situação das métricas | Classificação |
|---|---|
| Todas em `viavel` | `viavel` |
| Nenhuma `inviavel`, ao menos uma em `ressalva` | `viavel_com_ressalva` |
| Ao menos uma `inviavel` (ou sem medida) | `inviavel` |

**Ajuste pelo técnico:** no painel de resultados o técnico pode trocar a classe
de qualquer métrica e a decisão final, sempre com justificativa quando muda.

## 6 perfis: meio × cenário

Os limiares são resolvidos por **meio** (`lan`, `wifi_local`, `celular`) e
**cenário** (`sem_vpn` = Fase 1 / rede local; `com_vpn` = Fase 2 / pela VPN da
JE). `Get-PerfilLimiares -Meio <m> -Cenario <c>` (`src/core/Limiares.ps1`)
devolve o perfil plano que o motor de decisão consome.

- **LAN** e **Celular**: valores absolutos por cenário, editáveis.
- **Wi-Fi do local**: **não** guarda valores — herda da LAN + uma **folga**
  (aditiva para latência/jitter/perda/carregamento; percentual — *haircut* — para
  download/upload). Só a folga e o "Na bateria" são editáveis; Ideal/Limite
  aparecem só para conferência.
- **COM VPN** de LAN/Celular vem semeado de **SEM VPN + orçamento da VPN**
  (aditivo em ms/%, percentual em banda). O botão "Recalcular COM VPN" na tela do
  admin reaplica o orçamento; depois de semeado, os valores COM VPN são absolutos
  e editáveis.
- **"Na bateria"** é por **(meio × cenário × métrica)**: dá para, por exemplo,
  desligar o Upload só do Celular COM VPN.
- **Carregamento web** só existe **COM VPN** (a totalização só é alcançável pelo
  túnel); não há linha SEM VPN.

## Base ANATEL do cenário SEM VPN

O piso do "Limite" (inviável abaixo dele) no cenário **SEM VPN** foi ancorado nos
**valores de corte** da **Resolução Interna Anatel nº 444, de 23/06/2025**
(Documento de Valores de Referência — DVR), Tabela 5:

| Indicador | SMP (móvel → `celular`) | SCM (fixa → `lan` / `wifi_local`) |
|---|---|---|
| IND4 — Download / Upload | 2026: **7 / 1,5** Mbps (2027+: 10 / 1,5) | IND4-5: 5 / 1 · IND4-25: **25 / 5** |
| IND5 — Latência | **100 ms** | **80 ms** |
| IND6 — Jitter | **25 ms** | **40 ms** |
| IND7 — Perda de pacotes | **2 %** | **2 %** |

> Não é medição "conforme ANATEL": o DICON faz um teste pontual e usa o **valor
> de corte** como referência do limiar, não a metodologia de % de amostras num
> semestre. Os pisos foram adotados de forma **permissiva** (inclusão máxima de
> locais). COM VPN e carregamento web **não têm** fonte regulatória.

## Valores provisórios atuais (`config/limiares.exemplo.json`)

Ideal / Limite. Ajustar após validação em homologação contra `10.11.1.38`.

| Meio | Cenário | Latência (ms) | Jitter (ms) | Perda (%) | Download (Mbps) | Upload (Mbps) | Carreg. web (s) |
|---|---|---|---|---|---|---|---|
| LAN | SEM VPN | 20 / 80 | 10 / 40 | 0,5 / 2 | 25 / 5 | 5 / 1 | — |
| LAN | COM VPN | 50 / 110 | 20 / 50 | 1,5 / 3 | 18 / 4 | 3,5 / 1 | 4 / 12 |
| Wi-Fi local | SEM VPN | 30 / 90 | 15 / 45 | 1,5 / 3 | 20 / 4 | 4 / 0,8 | — |
| Wi-Fi local | COM VPN | 60 / 120 | 25 / 55 | 2,5 / 4 | 14,4 / 3,2 | 2,8 / 0,8 | 7 / 15 |
| Celular | SEM VPN | 40 / 100 | 10 / 25 | 1 / 2 | 15 / 7 | 5 / 1,5 | — |
| Celular | COM VPN | 60 / 130 | 15 / 35 | 1,5 / 4 | 10 / 5 | 4 / 1,5 | 6 / 18 |

**Orçamento da VPN** (semeia o COM VPN): latência +30 ms, jitter +10 ms, perda
+1 pp, download −30 %, upload −30 %.
**Folga do Wi-Fi** (sobre a LAN): latência +10 ms, jitter +5 ms, perda +1 pp,
download −20 %, upload −20 %, carregamento web +3 s.
(As linhas do Wi-Fi na tabela acima são ilustrativas — o app as calcula em
runtime a partir da LAN + folga.)

## A definir com o time de totalização / campo

- Banda mínima real por posto de trabalho da Junta Especial.
- Latência / jitter / perda em que a totalização começa a dar timeout.
- Tempo aceitável de carregamento (login vs. tela de digitação) e qual página.
- Orçamento da VPN real: medir Fase 1 vs Fase 2 no mesmo local em campo e
  recalibrar o bloco `orcamento_vpn` e a `folga` do Wi-Fi.
