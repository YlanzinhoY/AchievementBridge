# Achievement Bridge

Bridge de conquistas Windows-only em Zig 0.16.0. Ele detecta jogos e runtimes, acompanha conquistas locais de GSE/Goldberg, Steam, Ubisoft Connect e Uplay R2-compatible, normaliza os eventos, mantém um journal resiliente e mostra notificações nativas do Windows.

O acesso ao Steam Client é somente leitura por padrão. A única exceção é o comando manual `steam-unlock`, que exige `--confirm-steam-write`, opera sobre uma única conquista e aguarda a confirmação de `StoreStats`. Os watchers não escrevem na Steam.

## Compilar

```powershell
zig build
zig build test
```

O binário será criado em `zig-out/bin/achievement-bridge.exe`.

## GSE / Goldberg-compatible

Descobrir saves conhecidos:

```powershell
zig build run -- scan
```

Observar os roots GSE padrão com popup, som, recovery e metadata Steam automática:

```powershell
zig build run -- watch
```

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

## Escrita Steam explícita

Para um único desbloqueio autorizado pelo usuário:

```powershell
zig build run -- steam-unlock --appid 3751950 --achievement ACObsidian_Ach_10 --confirm-steam-write
```

O comando carrega os stats atuais, valida o API name, chama `SetAchievement` e só considera a operação armazenada após o callback de `StoreStats`. A Steam recusa conquistas protegidas pelo publicador. No Black Flag Resynced, as 49 entradas do schema local têm `permission = 2`; portanto o cliente não pode concedê-las e o comando termina sem chamar `StoreStats`.

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
- parser offline do spool oficial Ubisoft Connect;
- diagnóstico e watcher de saves Uplay R2-compatible;
- validação Ed25519 de manifest, SHA-256/assinatura de artefatos e cache atômico com rollback;
- build e testes no Zig 0.16.0.

Ainda não implementado:

- callbacks Steam (o watcher confirma estado consultando novamente);
- ícones no popup e screenshots automáticos;
- mapper comunitário Ubisoft↔Steam completo;
- download remoto do Provider Registry (o endpoint e a chave raiz ainda não foram publicados);
- bootstrap e opções no LuaTools;
- providers Epic/GOG/EA/Xbox além da detecção de runtime.

O watcher de arquivos atual usa polling leve de metadata e só relê JSON quando tamanho ou `mtime` muda. A migração para `ReadDirectoryChangesW` continua pendente.
