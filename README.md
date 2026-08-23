# Achievement Bridge

Bridge de conquistas Windows-only em Zig 0.16.0. Ele detecta jogos e runtimes, acompanha conquistas locais de GSE/Goldberg, Steam, Ubisoft Connect e Uplay R2-compatible, normaliza os eventos, mantém um journal resiliente e mostra notificações nativas do Windows.

O acesso direto ao `ISteamUserStats` é somente leitura por padrão. A única exceção estável é o comando manual `steam-unlock`, que exige `--confirm-steam-write` e tenta persistir no servidor com `StoreStats`. Separadamente, a integração LuaTools sincroniza automaticamente cada evento real do provider com o cache local da Steam; esse caminho não concede nada no servidor e não pede confirmação por conquista. Uma tentativa opt-in de toast do Steam Overlay está disponível como experimento e é descrita abaixo.

## Compilar

```powershell
zig build
zig build test
```

Os artefatos serão criados em `zig-out/bin/achievement-bridge.exe` e `zig-out/bin/achievement-bridge-cloud.dll`.

## GSE / Goldberg-compatible

Descobrir saves conhecidos:

```powershell
zig build run -- scan
```

Observar os roots GSE padrão com popup, som, recovery e metadata Steam automática:

```powershell
zig build run -- watch
```

O LuaTools usa `watch-all`, que mantém GSE, Ubisoft oficial e Uplay R2 em workers isolados dentro de um único processo Bridge:

```powershell
zig build run -- watch-all --no-notifications
```

Os eventos continuam num único stream ordenado; o popup rico e a sincronização local ficam sob responsabilidade do LuaTools.

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

Quando o LuaTools recebe um novo evento de GSE ou Uplay/Ubisoft mapeável para um AppID, ele resolve primeiro o API name pelo catálogo Steam e chama internamente:

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

O OpenSteamTool aceita uma única biblioteca em `[cloud].library`. Por isso, o host `achievement-bridge-cloud.dll` funciona como proxy: quando encontra `<Steam>\cloud_redirect.dll`, ele carrega a instalação existente e encaminha toda a ABI para preservar redirecionamento, sincronização e gravação dos saves; sem o CloudRedirect, continua oferecendo sozinho a parte necessária às conquistas. O LuaTools copia o host para `<Steam>\AchievementBridge`, configura o caminho em `opensteamtool.toml` e ele passa a valer na próxima abertura da Steam. Depois dessa instalação inicial, nenhum desbloqueio fecha ou reabre a Steam.

O resultado é local ao cliente Desktop, como no teste do Black Flag: a biblioteca e a UI do PC podem refletir a conquista, mas celular, perfil e servidor continuam inalterados porque esse fluxo não chama `StoreStats`.

### Toast do Steam Overlay (experimental)

O sync aceita uma tentativa opcional, desligada por padrão:

```powershell
achievement-bridge steam-local-sync --appid 3751950 --achievement ACObsidian_Ach_10 --timestamp 1787390253 --experimental-steam-notification
```

Depois de gravar o cache e pedir a recaptura ao host, o Bridge recarrega os stats pela ABI e lê a conquista de volta. `steam_confirmed=true` significa que a Steam devolveu o estado local como desbloqueado; `sync_unconfirmed` significa que a escrita não foi confirmada e, portanto, não deve produzir popup nem toast.

A rota experimental só chama `IndicateAchievementProgress(API_NAME, 1, 2)` depois dessa confirmação. Esse método continua sendo apenas o veículo visual do Overlay; a confirmação vem da releitura anterior, não do toast. O LuaTools também agrupa eventos por dois segundos e trata lotes de três ou mais como backfill de um save existente, sem sincronizá-los ou notificá-los automaticamente.

Validado manualmente no Windows com Assassin's Creed IV Black Flag (`appid=3751950`, `ACObsidian_Ach_10`, `permission=2`): a Steam recusou `SetAchievement`, aceitou `IndicateAchievementProgress`, exibiu o toast nativo `1/2` com nome e imagem localizados e o Bridge concluiu o sync local. O resultado foi reproduzido duas vezes com confirmação visual.

Os demais resultados (`not_new`, `already_unlocked`, `stats_unavailable`, `set_failed`, `progress_failed`, `store_failed` ou `steam_unavailable`) são explícitos no JSON para o host usar um fallback. O LuaTools só ativa essa rota para eventos novos em tempo real e mostra seu popup próprio quando a Steam não aceita nenhuma das tentativas nativas.

## Ubisoft Connect oficial

Ler os spools locais offline ou observá-los continuamente:

```powershell
zig build run -- ubisoft-scan
zig build run -- ubisoft-watch
```

O provider lê `%LOCALAPPDATA%\Ubisoft Game Launcher\spool`; não acessa a conta nem a rede.

## Uplay R2-compatible

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

É possível conferir o popup sem alterar o estado da Steam nem do save:

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

`host --once` executa um único ciclo. O detector reconhece Steamworks, GSE-compatible, Ubisoft Connect, Uplay R2, Epic EOS e GOG Galaxy e preserva múltiplos candidatos com confidence score.

## Journal

Por padrão, o journal fica em `%LOCALAPPDATA%\AchievementBridge\journal.jsonl`. No primeiro contato com um jogo/provider, conquistas antigas formam o baseline e não geram eventos. Em execuções posteriores, uma conquista nova encontrada no snapshot e ausente do journal é emitida com `recovered=true`. As chaves incluem o provider para impedir colisões entre IDs Steam, Ubisoft e GSE.

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
- validação Ed25519 de manifest, SHA-256/assinatura de artefatos e cache atômico com rollback;
- build e testes no Zig 0.16.0.

Ainda não implementado:

- callbacks Steam (o watcher confirma estado consultando novamente);
- ícones no popup e screenshots automáticos;
- mapper comunitário Ubisoft↔Steam completo;
- download remoto do Provider Registry (o endpoint e a chave raiz ainda não foram publicados);
- providers Epic/GOG/EA/Xbox além da detecção de runtime.

O watcher de arquivos atual usa polling leve de metadata e só relê JSON quando tamanho ou `mtime` muda. A migração para `ReadDirectoryChangesW` continua pendente.
