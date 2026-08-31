# DICON — Diagnóstico de Conectividade

Ferramenta de campo (PowerShell + GUI WPF) para diagnosticar a viabilidade de
conectividade de um local candidato a Junta Eleitoral Especial 2026 — TRE-MA.

**DICON** = **Di**agnóstico de **Con**ectividade.

O técnico roda a bateria de testes no notebook durante a visita e recebe na hora
uma classificação objetiva: **viável / viável com ressalva / inviável**.

## Fluxo do app

1. **Login** — o técnico seleciona o próprio nome (lista vem da planilha
   *Roteiros - Teste de Juntas Especiais*). Perfil `operador` para todos;
   `admin` só para George André Melo Castro, com PIN.
2. **Início** — logo, identificação do técnico e do roteiro, e o menu.
3. **Guia de bordo** — o roteiro do técnico: etapa, datas, trechos de viagem e
   os Locais das Juntas de cada cidade, com atalho para o diagnóstico.
4. **Diagnóstico de conectividade** — a bateria de testes por local.
5. **Administração** (Fase 2, só admin) — incluir/alterar Locais das Juntas.

## Como executar

```powershell
.\Iniciar-Diagnostico.ps1              # abre o app (login -> início)
.\Iniciar-Diagnostico.ps1 -SemUI -JuntaId ZE8-BALSAS-PRINCIPAL   # sem interface
.\tools\Testar-Gui.ps1 -Seed -Sair     # dev: baixa dados e abre no login
```

O script força modo STA (exigido pelo WPF) e faz auto-elevação UAC.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `config/` | Limiares, ambiente, envio, endpoint do Web App (`juntas.json`), PIN do admin (`admin.json`) |
| `src/core/` | Log, elevação UAC, processos, ambiente, fluxo, **sessão/login**, **papéis (admin)**, **juntas/tecnicos/roteiros** |
| `src/ui/` | Janela WPF MahApps.Metro (`MainWindow.xaml`: rail + login/início/guia/diagnóstico/admin), tema DICON (`Tema.xaml`) e code-behind |
| `src/testes/` | Coleta de métricas: latência (ping), banda (iperf3), carregamento web (Selenium) |
| `src/decisao/` | Motor de decisão que aplica os limiares às métricas |
| `src/saida/` | Montagem do JSON, gravação local e envio ao Apps Script |
| `apps-script/` | Web App (`Codigo.gs`): `?recurso=juntas\|tecnicos\|roteiros`. Deploy via `clasp` (`CLASP.md`) |
| `assets/` | Logo `Eleições 2026`; `marca/` = identidade visual do DICON (símbolo, ícone, `.ico`, paleta) |
| `data/` | Caches locais (gitignored): `juntas.json`, `tecnicos.json`, `roteiros.json`, `sessao.json` |
| `bin/`, `lib/Selenium/` | Binários portáteis (`iperf3`, drivers) e Selenium .NET |
| `lib/mahapps/` | DLLs do MahApps.Metro 2.4.10 (+ ControlzEx, Xaml.Behaviors) — versionadas |
| `resultados/` | `pendentes/` e `enviados/` |
| `tools/` | `Testar-Gui.ps1`, `Testar-Fluxo.ps1` (headless), `Definir-PIN-Admin.ps1` |
| `docs/` | Manual do técnico, referência de limiares, contrato do JSON |

## Dependências de terceiros

Não são versionadas. Monte a pasta `bin/` (e `lib/Selenium/`) numa máquina com
internet antes de ir a campo — ver `docs/manual-tecnico.md`.

## Pré-requisitos

- Windows 11, Windows PowerShell 5.1 (ou PowerShell 7)
- VPN da Justiça Eleitoral conectada no momento do teste
- Servidor `iperf3` ativo no CPD (Ubuntu), acessível pela VPN

## Status

Esqueleto inicial (v0.1.0). Itens em aberto: limiares definitivos, endpoint do
Apps Script e estratégia de envio (na hora vs. offline-first).
