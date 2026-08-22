# References

O código deste repositório foi implementado do zero. As fontes abaixo foram usadas para entender formatos e comportamentos externos.

- Zig 0.16.0 documentation and standard library — MIT License.
- `alex47exe/gse_fork` (`dll/steam_user_stats_achievements.cpp`, `dll/local_storage.cpp` e `tools/steam_stats_converter`) — LGPL-3.0. Usado como referência do formato produzido; nenhum código foi copiado.
- `Shirowwww/Achievement-Watcher-Next` (`app/parser/goldberg.js`) — LGPL-3.0. Usado como referência de caminhos padrão, layouts portáteis e variantes de representação; nenhum código foi copiado.
- `steamforge-app/steamforge/internal/steam` — MIT License. Referência da camada Steam Windows (`loader`, `loader_windows`, `client`, `vtable`, `isteamclient`, `isteamuserstats`, `userstats_cache` e `callback`). Árvore conferida no commit `f9568bb5d32a94217cfd2c8b50788329f0214890`; a implementação em Zig é própria.
- Steamworks `ISteamUserStats` — documentação oficial usada para validar as operações somente leitura: https://partner.steamgames.com/doc/api/ISteamUserStats
- Microsoft `Shell_NotifyIconW` — documentação oficial do popup nativo: https://learn.microsoft.com/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw
- Microsoft `ReadDirectoryChangesW` — referência para substituir o polling de arquivos em uma etapa futura: https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-readdirectorychangesw
- `Shirowwww/Achievement-Watcher-Next/app/parser/ubisoftOfficial.js` — LGPL-3.0. Referência do spool offline Ubisoft Connect; o parser protobuf foi reimplementado em Zig.
- `Shirowwww/Achievement-Watcher-Next/app/parser/uplayR2.js` — LGPL-3.0. Referência do layout e precedência do runtime Uplay R2-compatible; nenhum código JavaScript foi copiado.
- `Selectively11/CloudRedirect` (`src/common/cr_api.h` e `src/common/stats_store.cpp`) — MIT License. Referência da ABI `CR_*`, do layout Binary KeyValues e do cálculo de CRC; o parser, escritor e proxy foram implementados do zero em Zig.
- `OpenSteam001/OpenSteamTool` (`CloudRedirectHost` e o hook de `CMsgClientGetUserStatsResponse`) — GPL-3.0. Referência do ponto de integração e do contrato dos achievement blocks; nenhum código C++ foi incorporado.

Não há porte Linux planejado nesta fase.
