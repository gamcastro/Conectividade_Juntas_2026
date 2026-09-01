# DICON — instalar num notebook/computador de campo

Ferramenta portátil: **uma pasta única**, sem instalador. O PowerShell 5.1 e o
WPF já vêm no Windows 10/11. Os binários de terceiros (Ookla Speedtest, iperf3,
geckodriver/chromedriver, Selenium) **não** ficam no repositório — o script de
setup baixa. As configurações reais (`config/*.json`) também não vão ao git — o
setup cria a partir dos `*.exemplo.json`.

---

## Atalho: baixar + instalar num comando (com internet)

No PowerShell (janela normal, com internet). Instala em `C:\DICON`, garante o
`speedtest.exe` (baixa + desbloqueia) e roda o setup. Se já houver DICON na
pasta, ele **atualiza** o código em vez de reinstalar.

```
iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Baixar-e-Instalar.ps1')
```

Opções — definir **antes** do comando (todas opcionais):

```
$env:DICON_DEST     = 'D:\DICON'          # padrão: C:\DICON
$env:DICON_ENDPOINT = 'https://.../exec'  # URL /exec do Web App (pula a pergunta)
$env:DICON_PIN      = '1234'              # PIN do admin (pula a pergunta)
$env:DICON_IPERF    = '10.11.9.20'        # servidor iperf3
$env:DICON_DEPSZIP  = 'D:\pen\DICON-deps.zip'
```

O resto (perguntas do setup, demais binários, primeira abertura) é igual ao
passo a passo abaixo.

---

## Passo a passo (com internet)

1. **Baixar a pasta**
   - Sem git: abra
     `https://github.com/gamcastro/Conectividade_Juntas_2026/archive/refs/heads/homologacao.zip`
     e salve o ZIP.
   - Com git: `git clone -b homologacao https://github.com/gamcastro/Conectividade_Juntas_2026.git C:\DICON`

2. **Extrair** para `C:\DICON\` (ou outra pasta gravável — pen drive serve).
   Se baixou o ZIP: clique com o botão direito no ZIP → **Propriedades** →
   marque **Desbloquear** → OK, e só então extraia.

3. **Rodar o setup** — abra o PowerShell **na pasta** e execute:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Instalar-DICON.ps1
   ```
   Ele vai perguntar:
   - **URL /exec do Web App** (Apps Script) — cole a URL; Enter pula.
   - **IP/host do servidor iperf3** no CPD — Enter pula (dá para editar depois na
     tela de Administração).
   - **PIN do administrador** (4 a 6 dígitos) — digitado duas vezes.

   O setup destrava os arquivos, cria `data\ resultados\ relatorios\ logs\`,
   materializa `config\*.json`, grava o PIN e baixa os binários. Se algum
   download falhar, ele diz **qual arquivo** falta e **de onde baixar** — é só
   colocar na pasta indicada e rodar de novo.

4. **Abrir a ferramenta**
   ```
   .\Iniciar-Diagnostico.bat
   ```
   Se o SmartScreen avisar "editor desconhecido": **Mais informações → Executar
   assim mesmo** (uma vez).

5. **Primeira vez, com internet**: na tela inicial clique em **Atualizar dados**
   para baixar a lista das Juntas/roteiros (fica em cache e roda offline depois).

---

## Sem internet no local de instalação (preparo offline)

Prepare **uma** máquina com internet (passos acima), depois zipe as pastas de
binários e leve num pen drive:

```
Compress-Archive -Path .\tools\speedtest.exe,.\tools\speedtest.md,.\bin,.\lib\Selenium -DestinationPath DICON-deps.zip
```

Nas demais máquinas (offline), extraia a pasta e rode:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Instalar-DICON.ps1 -DepsZip D:\pendrive\DICON-deps.zip
```

---

## Atualizar depois

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Atualizar-DICON.ps1
```

Atualiza só o **código** (`src\`, `lib\mahapps\`, `assets\`, `tools\*.ps1`,
`Iniciar-Diagnostico.*`). **Não** toca em `config\`, `data\`, `bin\`,
`resultados\` nem `relatorios\`.

---

## O que precisa existir para cada parte funcionar

| Parte | Precisa de | Sem isso |
|---|---|---|
| Interface | PowerShell 5.1 + WPF (nativos do Windows) + `lib/mahapps/` (no repo) | não abre |
| Passo 3 — Speedtest | `tools/speedtest.exe` | card mostra erro |
| Passo 4 — banda VPN | `bin/iperf3/iperf3.exe` + `config/ambiente.json` (servidor) | card mostra erro |
| Passo 4 — carregamento web | geckodriver/chromedriver + `lib/Selenium/` | métrica fica sem medida (stub) |
| Admin (limiares) | `config/admin.json` (PIN) + URL do Web App | tela abre, salvar bloqueia |

## Licença do speedtest.exe

O Ookla Speedtest CLI é **proprietário**. Quem executa o setup aceita o EULA da
Ookla ao baixá-lo. Por isso o binário **nunca** é versionado nem distribuído
pelo TRE — é sempre baixado da fonte oficial na máquina de destino.
