# Achievement Bridge

Bridge de conquistas Windows-only com núcleo em Zig 0.16.0, API local em Go e interface Typer/Rich em Python. Ele detecta jogos e runtimes, acompanha conquistas locais de GSE/Goldberg, RUNE, Rockstar Social Club, Steam, Ubisoft Connect e Uplay R2-compatible, normaliza os eventos, mantém um journal resiliente e mostra notificações nativas do Windows.

O acesso direto ao `ISteamUserStats` é somente leitura por padrão. As exceções de escrita são os comandos manuais explicitamente confirmados e os syncs GSE/RUNE/Rockstar/Uplay R2 verificados. A prévia visual nunca escreve na Steam; os syncs só prosseguem após reler o save e comprovar o desbloqueio para o mesmo AppID/API name. A API standalone sincroniza cada evento real do provider com o cache local da Steam como fallback, mesmo quando a CLI não está exibindo os logs. Uma tentativa opt-in de toast de progresso do Steam Overlay também está disponível como experimento e é descrita abaixo.

## Compilar

```powershell
zig build
go -C api build -o ..\zig-out\bin\achievement-bridge-api.exe .\cmd\achievement-bridge-api
```

Os artefatos serão criados em `zig-out/bin/achievement-bridge.exe`, `zig-out/bin/achievement-bridge-api.exe` e `zig-out/bin/achievement-bridge-cloud.dll`.

## Arquitetura separada

A interface Python cuida somente de entrada e apresentação. Catálogo, descoberta de jogos e simulação de toast são solicitados à API Go em `127.0.0.1:47650`. O gateway inicia e supervisiona o núcleo Zig persistente, comunicando-se com ele por JSON delimitado por linha em `127.0.0.1:47651`. Apenas o Zig conhece a ABI Steam e controla a sessão durante cada operação completa; o Go traduz o protocolo interno para HTTP/JSON e nenhum dos dois serviços aceita conexões fora do loopback.

Essa divisão evita criar um novo processo Zig a cada clique e deixa uma futura GUI consumir a mesma API sem duplicar regras. Ao ativar o monitor, os providers passam a rodar dentro desse mesmo core, a API consome e sincroniza os eventos em segundo plano e os logs chegam à interface por Server-Sent Events. O estado normal é um processo `achievement-bridge.exe` e um processo `achievement-bridge-api.exe`; abrir ou fechar a tela de logs não cria nem encerra outro Zig. O contrato e os limites de cada camada estão detalhados em [`docs/architecture.md`](docs/architecture.md).

Quando a CLI inicia esse par, ele permanece ativo em segundo plano. `Ctrl+C` fecha apenas a visualização dos logs e sair da CLI fecha somente a interface. O botão **Desativar Bridge**, o comando `bridge-cli.cmd stop` ou `POST /v1/shutdown` encerram explicitamente a API e seu core.

## CLI aberta

`achievement_bridge_cli.py` é uma interface standalone em Python 3.10+, construída com Typer e Rich.
Ela inicia o gateway Go quando necessário, mantém os logs visíveis e persistentes, informa qual jogo está ativo e exibe
a compatibilidade calculada pelo núcleo. A sincronização verificada pertence à API e continua sem a tela aberta. A CLI não contém nem
depende de código do LuaTools. Na primeira abertura, `bridge-cli.cmd` cria uma `.venv` isolada e instala
automaticamente a dependência declarada em `requirements-cli.txt`; em uma árvore de fontes também compila o gateway se ele ainda não existir.

No Windows, compile o núcleo e abra a CLI:

```powershell
zig build -Doptimize=ReleaseSafe
go -C api build -o ..\zig-out\bin\achievement-bridge-api.exe .\cmd\achievement-bridge-api
.\bridge-cli.cmd
```

A abertura padrão mostra um menu com o estado da Steam e do Bridge. Escolha `1` para ativar o
monitor e acompanhar os eventos ao vivo, `2` para desativar explicitamente o Bridge, `3` para consultar a compatibilidade dos jogos instalados,
`4` para escolher um jogo e ver suas conquistas disponíveis, `5` para visualizar uma prévia segura do
popup do Achievement Bridge ou `0` para sair. Nada começa a monitorar até o usuário escolher **Ativar Bridge**.

Os logs ficam em `%LOCALAPPDATA%\AchievementBridge\bridge-cli.log` e `%LOCALAPPDATA%\AchievementBridge\bridge-api.log`. `Ctrl+C` volta ao menu sem
interromper o monitor. A API de loopback garante uma única instância; use **Desativar Bridge** quando quiser encerrá-la.

Para automação ou uso avançado, o monitor também pode ser iniciado diretamente:

```powershell
.\bridge-cli.cmd start
```

Nesse modo, `--allow-duplicate` existe apenas para diagnóstico consciente.

Para listar os jogos instalados:

```powershell
.\bridge-cli.cmd games
.\bridge-cli.cmd games --json
```

Os estados exibidos são:

- `COMPLETO`: o Bridge detecta o evento e sincroniza com a Steam;
- `NATIVO`: Steamworks oficial, portanto o jogo não precisa do Bridge;
- `SÓ DETECTA`: o evento é detectável, mas a CLI ainda não sincroniza sozinha;
- `AGUARDA DADOS`: a integração foi preparada, mas ainda não apareceu um estado local que possa ser associado com segurança ao jogo;
- `SEM SUPORTE`: runtime sem provider de conquistas implementado.

O catálogo de um jogo também pode ser consultado diretamente pelo AppID:

```powershell
.\bridge-cli.cmd achievements 2638890
```

Uma prévia visual pode ser solicitada pelo menu ou diretamente pelo API name:

```powershell
.\bridge-cli.cmd simulate-popup 2638890 ACHIEVEMENT_050
```

O simulador usa o popup nativo do Windows pertencente ao Achievement Bridge, preenchido com nome,
descrição e raridade obtidos do catálogo Steam. Ele não chama `SetAchievement`, `ClearAchievement` ou
`StoreStats`, não altera timestamps e pode inclusive visualizar conquistas já obtidas. O toast nativo
da Steam não é usado na prévia porque ele exige uma mudança real de estado que pode ser persistida ou
restaurada posteriormente pelo cliente. No menu interativo, a CLI volta diretamente à lista de
conquistas do mesmo jogo para permitir quantas prévias o usuário desejar.
Para opcionalmente aguardar um jogo abrir antes da transação:

```powershell
.\bridge-cli.cmd simulate-popup 2638890 ACHIEVEMENT_050 --wait-for-game --game-dir "D:\SteamLibrary\steamapps\common\OnimushaWotS"
```

## Rockstar Social Club

O detector reconhece instalações Rockstar oficiais e compatíveis, incluindo jogos com
`socialclub.dll`, `title.rgl`, `socialclub_emu.ini` ou `RUNE64.dll`. O provider comum procura estados locais
de conquistas nos perfis do Social Club e nos diretórios públicos usados por emuladores. A associação
ao AppID compara dinamicamente o título e a pasta do perfil com toda a biblioteca Steam instalada;
aliases conhecidos existem apenas como fallback. Jogos que não publicam esse estado em arquivo podem ter um
adaptador isolado em `src/providers/rockstar/games`, sem colocar regras específicas no núcleo do provider.

O GTA V Enhanced possui o primeiro desses adaptadores. Enquanto `GTA5_Enhanced.exe` está aberto, ele localiza
por assinatura a rotina `HAS_ACHIEVEMENT_BEEN_PASSED`, lê passivamente a lista viva do Social Club e mapeia os
77 IDs de PC para seus API names Steam. Nenhum endereço absoluto é fixado, nenhum código é injetado e a memória
do jogo nunca é alterada. A primeira leitura vira baseline; somente um ID acrescentado depois disso produz evento
e sincronização. Como fallback para um jogo fechado, o cabeçalho público dos saves `SGTA*` ainda comprova `ACH00`
quando o progresso é igual ou superior a 1,6%.

O catálogo, os nomes e as imagens continuam vindo da Steam. Se o runtime for detectado, mas o perfil
só contiver blobs proprietários como `cfg.dat`, `pc_settings.bin` ou um `achievements.dat` não
decodificável, a CLI mostra `AGUARDA DADOS`: as conquistas podem ser consultadas e usadas no simulador,
mas o Bridge não adivinha nem envia desbloqueios. Assim que um estado legível ou um adaptador do título estiver
disponível, o watcher cria o baseline e passa a sincronizar apenas transições novas de bloqueada para desbloqueada.

Quando uma conquista GSE/RUNE/Rockstar é emitida, a API comprova novamente a mesma evidência que originou o
evento — arquivo do provider ou estado vivo do adaptador — para o mesmo AppID/API name antes de escrever na
Steam. Primeiro tenta `SetAchievement` + `StoreStats`; schemas protegidos usam o cache local nativo como
fallback, com backup atômico.

## Instalador Windows

O instalador é gerado com Velopack 1.2.0. A CLI Typer/Rich é congelada em uma pasta standalone pelo
PyInstaller, portanto o computador do usuário não precisa ter Python, Go, Zig ou .NET instalado. O setup
é por usuário, cria atalhos no Menu Iniciar e na área de trabalho, registra um desinstalador e já usa o
formato de releases necessário para atualizações futuras.

Para gerar uma release local a partir dos fontes:

```powershell
.\scripts\build-installer.ps1 -Version 0.1.12
```

O script compila o núcleo Zig em `ReleaseSafe`, executa a suíte existente, compila o gateway Go, gera o ícone, empacota a CLI e grava o setup,
o pacote completo e o feed Velopack em `dist`. Para reconstruir com binários Zig já existentes e
limpar os artefatos de release anteriores:

```powershell
.\scripts\build-installer.ps1 -Version 0.1.12 -SkipZigBuild -SkipGoBuild -CleanReleases
```

As ferramentas de build ficam fixadas em `requirements-build.txt` e `.config/dotnet-tools.json`.

## GSE / Goldberg-compatible

Descobrir saves conhecidos:

```powershell
zig build run -- scan
```

Observar os roots GSE padrão com popup, som, recovery e metadata Steam automática:

```powershell
zig build run -- watch
```

O comando de compatibilidade `watch-all` mantém GSE, RUNE, Ubisoft oficial e Uplay R2 em workers isolados dentro de um único processo Bridge:

```powershell
zig build run -- watch-all --no-notifications
```

Na CLI standalone, esses mesmos workers são ativados dentro do core `serve` pela API Go. A API consome os eventos e solicita a sincronização ao mesmo core por uma chamada estruturada; o stream SSE existe apenas para interfaces exibirem os logs. Um worker de sessões também informa quando um executável de jogo abre ou fecha e quais providers foram detectados. Cada acesso Steam continua limitado à duração da operação para evitar que um jogo permaneça incorretamente marcado como aberto.

A CLI standalone faz a mesma orquestração para GSE/RUNE. O comando verificado GSE também pode ser
usado diretamente:

```powershell
achievement-bridge gse-steam-sync --appid 2638890 --achievement ACHIEVEMENT_002
```

## RUNE

O provider RUNE descobre automaticamente `%PUBLIC%\Documents\Steam\RUNE\<appid>\achievements.ini`,
lê os API names e timestamps nativos e observa alterações sem modificar o save. Para diagnóstico:

```powershell
zig build run -- rune-scan
zig build run -- rune-watch
```

No primeiro contato, conquistas existentes formam o baseline e não geram uma tempestade de popups.
Depois disso, cada nova seção com `Achieved=1` em `achievements.ini` vira um evento `provider=rune`.
Como os IDs do RUNE preservam o API name da Steam, o LuaTools resolve o metadata oficial e passa o
evento pelo mesmo sync local, popup e projeção ao vivo usados pelos outros providers.

Para eventos RUNE, o LuaTools primeiro chama a rota comprovada:

```powershell
achievement-bridge rune-steam-sync --appid 3046600 --achievement ACHIEVEMENT_02
```

Essa rota não aceita uma confirmação cega da UI: redescobre
`%PUBLIC%\Documents\Steam\RUNE\<appid>\achievements.ini` e recusa AppID ausente, API name ausente ou
conquista sem `Achieved=1`. Só então chama `SetAchievement` e aguarda o callback bem-sucedido de
`StoreStats`. Se a publicadora proteger o schema ou a Steam estiver indisponível, o LuaTools continua
com o sync local e seu popup/UI como fallback.

Observar um save customizado/portátil:

```powershell
zig build run -- watch --root "D:\Jogos\MeuJogo\save"
```

`--root` aceita tanto um root com subpastas `<appid>` quanto a própria pasta `<appid>` contendo `achievements.json`. Mais de um `--root` pode ser informado. Um schema local também pode ser usado:

```powershell
zig build run -- watch --schema "D:\Jogo\steam_settings\achievements.json" --language brazilian
```

## Steam somente leitura

Listar conquistas, timestamps, nomes, descrições e raridade através do Steam Client:

```powershell
zig build run -- steam-read --appid 1145350
```

Observar mudanças mantendo uma única sessão read-only:

```powershell
zig build run -- steam-watch --appid 1145350
```

Para consumidores como o LuaTools, o catálogo JSON combina metadata e estado do Steam Client com
overrides estritamente locais. A Steam sempre tem prioridade quando já informa o desbloqueio:

```powershell
zig build run -- catalog --appid 1145350
```

O catálogo inclui API name, nome, descrição, hashes dos ícones normal/bloqueado, timestamp, raridade
global e a origem do estado. Nenhuma operação desse comando escreve por `ISteamUserStats`.

## Estado local explícito

Uma conquista pode ser persistida apenas para interfaces locais, sem chamar `SetAchievement` nem
`StoreStats`. O API name é validado contra o catálogo Steam e a confirmação é obrigatória:

```powershell
zig build run -- local-record --appid 1145350 --achievement AchClearErebus --confirm-local-write
```

Por padrão, o arquivo fica em `%LOCALAPPDATA%\AchievementBridge\local-achievements.json`. O override
local nunca substitui um estado desbloqueado retornado pelo cliente Steam e não aparece no celular,
perfil comunitário ou demais superfícies que consultam apenas os servidores Steam.

## Escrita Steam explícita

Para um único desbloqueio autorizado pelo usuário:

```powershell
zig build run -- steam-unlock --appid 3751950 --achievement ACObsidian_Ach_10 --confirm-steam-write
```

O comando carrega os stats atuais, valida o API name, chama `SetAchievement` e só considera a operação armazenada após o callback de `StoreStats`. A Steam recusa conquistas protegidas pelo publicador. No Black Flag Resynced, as 49 entradas do schema local têm `permission = 2`; portanto o cliente não pode concedê-las e o comando termina sem chamar `StoreStats`.

## Sincronização local automática

Quando o LuaTools recebe um novo evento de GSE, RUNE ou Uplay/Ubisoft mapeável para um AppID, ele resolve primeiro o API name pelo catálogo Steam e chama internamente:

```powershell
achievement-bridge steam-local-sync --appid 3751950 --achievement ACObsidian_Ach_10 --timestamp 1787390253
```

Esse comando não tem confirmação manual porque não é uma tela de edição: ele é a continuação automática de um desbloqueio observado durante o jogo. A operação:

- lê `UserGameStatsSchema_<appid>.bin` e resolve `stat_id`, bit e `permission`;
- preserva todos os outros stats e campos Binary KeyValues;
- altera somente o bit e timestamp correspondentes e recalcula o CRC nativo;
- cria backup antes de cada mudança e substitui o arquivo de forma atômica;
- atualiza o overlay em memória da Steam pelo host carregado no processo;
- é idempotente, portanto repetir o mesmo evento não muda o timestamp original.

O OpenSteamTool aceita uma única biblioteca em `[cloud].library`. Por isso, o host `achievement-bridge-cloud.dll` funciona como proxy: quando encontra `<Steam>\cloud_redirect.dll`, ele carrega a instalação existente e encaminha toda a ABI para preservar redirecionamento, sincronização e gravação dos saves; sem o CloudRedirect, continua oferecendo sozinho a parte necessária às conquistas. O overlay confirmado é persistido por conta em `<Steam>\AchievementBridge\achievement-overlays-v1.bin`, com cabeçalho versionado, CRC e substituição atômica, e recarregado na próxima sessão da Steam. A CLI standalone instala uma cópia versionada do host em `<Steam>\AchievementBridge` e configura `opensteamtool.toml` automaticamente ao iniciar o monitor; o mesmo preparo pode ser executado explicitamente com `achievement-bridge-cli setup`. A alteração passa a valer na próxima abertura da Steam. Depois dessa instalação inicial, nenhum desbloqueio fecha ou reabre a Steam.

O resultado é local ao cliente Desktop, como no teste do Black Flag: a biblioteca e a UI do PC podem refletir a conquista, mas celular, perfil e servidor continuam inalterados porque esse fluxo não chama `StoreStats`.

### Toast do Steam Overlay (experimental)

O sync aceita uma tentativa opcional, desligada por padrão:

```powershell
achievement-bridge steam-local-sync --appid 3751950 --achievement ACObsidian_Ach_10 --timestamp 1787390253 --experimental-steam-notification
```

Depois de gravar o cache e pedir a recaptura ao host, o Bridge relê o arquivo nativo e valida CRC, bit e timestamp. `cache_confirmed=true` comprova que o desbloqueio está persistido no cache local da Steam. Em paralelo, o Bridge recarrega os stats pela ABI: `steam_confirmed=true` significa que a visão em memória da Steam também já devolveu o estado como desbloqueado. Essa segunda confirmação pode continuar falsa até uma atualização ou reinício do cliente mesmo quando o cache local já está correto.

A rota experimental só chama `IndicateAchievementProgress(API_NAME, 1, 2)` depois de `cache_confirmed=true` e de o host confirmar a persistência atômica do overlay por conta/AppID. Esse método continua sendo apenas o veículo visual do Overlay: a confirmação vem da releitura do cache e da gravação persistente anterior, não do toast. Isso permite o toast nativo mesmo quando a ABI permanece obsoleta por `permission=2`; se a Steam recusar o veículo visual, o LuaTools usa seu popup próprio. O LuaTools também agrupa eventos por dois segundos e trata lotes de três ou mais como backfill de um save existente, sem sincronizá-los ou notificá-los automaticamente.

Validado manualmente no Windows com Assassin's Creed IV Black Flag (`appid=3751950`, `ACObsidian_Ach_10`, `permission=2`): a Steam recusou `SetAchievement`, aceitou `IndicateAchievementProgress`, exibiu o toast nativo `1/2` com nome e imagem localizados e o Bridge concluiu o sync local. O resultado foi reproduzido duas vezes com confirmação visual.

Os demais resultados (`not_new`, `sync_unconfirmed`, `already_unlocked`, `stats_unavailable`, `set_failed`, `progress_failed`, `store_failed` ou `steam_unavailable`) são explícitos no JSON para o host usar um fallback. O LuaTools só ativa essa rota para eventos novos em tempo real e mostra seu popup próprio quando a persistência local foi relida com sucesso e a Steam não aceitou nenhuma das tentativas nativas.

## Ubisoft Connect oficial

Ler os spools locais offline ou observá-los continuamente:

```powershell
zig build run -- ubisoft-scan
zig build run -- ubisoft-watch
```

O provider lê `%LOCALAPPDATA%\Ubisoft Game Launcher\spool`; não acessa a conta nem a rede.

## Uplay R2-compatible

Preparar automaticamente a conexão usando o catálogo oficial já carregado pela Steam:

```powershell
python achievement_bridge_cli.py prepare-support 2842040
```

Esse fluxo gera `achievements_schema.json`, habilita o log/estado local e cria um manifesto em `%LOCALAPPDATA%\AchievementBridge\support\games\<SteamAppID>\support.json`. O manifesto registra separadamente as capacidades de detectar, monitorar, mapear, sincronizar e exibir popup. A CLI só mostra `COMPLETO` quando o ProductID do provider, o `achievements.json`, o catálogo e o mapeamento Steam estão presentes; antes da primeira inicialização do jogo, mostra `AGUARDA DADOS`.

O ProductID é aprendido dinamicamente da inicialização real do loader e associado ao Steam AppID pelo manifesto. Portanto, a solução não mantém uma tabela fixa por jogo. API names com sufixo numérico, como `Outlaws_Ach_19` e `ACObsidian_Ach_30`, são convertidos para o objetivo local correspondente e novamente validados antes de qualquer sincronização Steam.

Diagnosticar uma instalação sem modificá-la:

```powershell
zig build run -- uplay-r2-diagnose --game-dir "D:\Jogos\MeuJogo"
```

Preparar uma instalação a partir de um catálogo ordenado como `ACBFR.json`:

```powershell
zig build run -- uplay-r2-prepare --game-dir "D:\Jogos\MeuJogo" --catalog ".\ACBFR.json"
```

O preparador valida a contagem e a unicidade de `steam_order`, usa `steam_order + 1` como ID nativo, gera `achievements_schema.json`, habilita `Achievements = 1` e preserva os arquivos substituídos com o sufixo `.achievement-bridge.bak`. O campo legado `id` do catálogo é ignorado: no arquivo ACBFR ele contém valores repetidos que não são IDs de conquistas.

Ler ou observar o `achievements.json` do runtime:

```powershell
zig build run -- uplay-r2-scan
zig build run -- uplay-r2-watch --root "%APPDATA%\Goldberg UplayEmu Saves"
```

Quando houver uma versão Steam equivalente, `--appid` habilita o mapper exato por sufixo numérico. Para Black Flag Resynced:

```powershell
zig build run -- uplay-r2-watch --appid 3751950
```

É possível conferir o popup seguro do Achievement Bridge sem alterar o estado da Steam:

```powershell
zig build run -- notify-test --appid 3751950 --achievement ACObsidian_Ach_10
```

Para disparar essa prévia somente quando o executável do jogo abrir:

```powershell
zig build run -- notify-test --appid 3751950 --achievement ACObsidian_Ach_10 --wait-for-game --game-dir "D:\Jogos\MeuJogo"
```

O número no API name é apenas o ID interno. O popup omite esse detalhe e identifica o percentual lido da Steam como raridade global, não como progresso pessoal.

## Detecção e sessões

Listar a biblioteca Steam, analisar um jogo e observar o ciclo de vida dos processos:

```powershell
zig build run -- games
zig build run -- probe --game-dir "D:\Jogos\MeuJogo"
zig build run -- host
```

`host --once` executa um único ciclo. O detector reconhece Steamworks, GSE-compatible, RUNE-compatible, Ubisoft Connect, Uplay R2, Epic EOS e GOG Galaxy e preserva múltiplos candidatos com confidence score.

## Journal

Por padrão, o journal fica em `%LOCALAPPDATA%\AchievementBridge\journal.jsonl`. No primeiro contato
com um save que já existia antes do monitor, conquistas antigas formam o baseline e não geram eventos.
Se o GSE criar seu primeiro snapshot enquanto o monitor já está rodando, a primeira conquista é
tratada como evento ao vivo e não é engolida pelo baseline. Em execuções posteriores, uma conquista
nova encontrada no snapshot e ausente do journal é emitida com `recovered=true`. As chaves incluem o
provider para impedir colisões entre IDs Steam, Ubisoft e GSE.

## Estado da implementação

Implementado:

- snapshots, diff, timestamps, baseline, recovery e deduplicação por provider;
- metadata local GSE e metadata/raridade via Steam;
- popup e som nativos do Windows;
- catálogo Steam via Registry, `libraryfolders.vdf` e app manifests;
- process watcher, `GameSession`, runtime detector, provider resolver e múltiplos providers;
- Steam adapter read-only e watcher por polling;
- parser Binary KeyValues, mapeamento schema→bit, CRC e escrita atômica do cache local;
- proxy ABI compatível com CloudRedirect e IPC para refletir desbloqueios durante a sessão da Steam;
- parser offline do spool oficial Ubisoft Connect;
- diagnóstico e watcher de saves Uplay R2-compatible;
- parser INI, descoberta e watcher de saves RUNE;
- CLI Python standalone com logs, inventário de compatibilidade e sync verificado GSE/RUNE;
- validação Ed25519 de manifest, SHA-256/assinatura de artefatos e cache atômico com rollback;
- build e testes no Zig 0.16.0.

Ainda não implementado:

- callbacks Steam (o watcher confirma estado consultando novamente);
- ícones no popup e screenshots automáticos;
- mapper comunitário Ubisoft↔Steam completo;
- download remoto do Provider Registry (o endpoint e a chave raiz ainda não foram publicados);
- providers Epic/GOG/EA/Xbox além da detecção de runtime.

O watcher de arquivos atual usa polling leve de metadata e só relê JSON quando tamanho ou `mtime` muda. A migração para `ReadDirectoryChangesW` continua pendente.
