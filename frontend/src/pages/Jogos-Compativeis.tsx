import { A } from '@solidjs/router'
import { createResource, For, Show } from 'solid-js'
import { api } from '@/services/api-client'
import type { GameSupportStatus } from '@/types'

function statusColor(status: GameSupportStatus) {
  switch (status) {
    case 'COMPLETO':
      return '#61ffca'

    case 'NATIVO':
      return '#82e2ff'

    case 'SÓ DETECTA':
    case 'AGUARDA DADOS':
      return '#ffca85'

    case 'SEM CATÁLOGO':
      return '#ffca85'

    case 'SEM SUPORTE':
      return '#ff6767'
  }
}

export default function GamesPage() {
  const [games] = createResource(() => api.listGames(true))

  return (
    <section class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
      <Show when={games.loading}>
        <p class="mb-6 text-sm font-medium text-primary">Analisando a biblioteca Steam...</p>
      </Show>

      <Show when={games.error}>
        <p class="rounded-lg border border-destructive/40 bg-destructive/10 p-4 text-destructive">
          Erro: {games.error?.message}
        </p>
      </Show>

      <Show when={games()}>
        {(data) => (
          <>
            <div class="overflow-x-auto rounded-lg border border-primary/25 bg-card">
            <table class="w-full min-w-[760px] border-collapse text-left text-sm">
              <thead>
                <tr class="border-b border-primary/25 bg-primary/10 text-primary">
                  <th class="px-4 py-3">AppID</th>
                  <th class="px-4 py-3">Status</th>
                  <th class="px-4 py-3">Provedor</th>
                  <th class="px-4 py-3">Conf.</th>
                  <th class="px-4 py-3">Conq.</th>
                  <th class="px-4 py-3">Jogo</th>
                </tr>
              </thead>

              <tbody>
                <For each={data().games}>
                  {(game) => (
                    <tr class="border-b border-border last:border-0 hover:bg-primary/5">
                      <td class="px-4 py-3 font-mono text-muted-foreground">{game.app_id}</td>

                      <td
                        class="px-4 py-3"
                        style={{
                          color: statusColor(game.status),
                          'font-weight': 'bold',
                        }}
                      >
                        {game.status}
                      </td>

                      <td class="px-4 py-3">{game.provider}</td>

                      <td class="px-4 py-3">
                        {game.provider === 'none'
                          ? '—'
                          : `${game.confidence}%`}
                      </td>

                      <td class="px-4 py-3">
                        {game.achievement_count ?? '—'}
                      </td>

                      <td class="px-4 py-3 font-medium">
                        <Show
                          when={(game.achievement_count ?? 0) > 0}
                          fallback={game.name}
                        >
                          <A
                            href={`/conquistas/${game.app_id}`}
                            class="text-primary underline-offset-4 hover:underline"
                          >
                            {game.name}
                          </A>
                        </Show>
                      </td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
            </div>

            <div class="mt-6 grid gap-2 rounded-lg border border-primary/20 bg-card p-5 text-sm text-muted-foreground">
              <p>
                <span class="font-semibold text-[#61ffca]">COMPLETO</span>
                {' '}Bridge detecta e sincroniza com a Steam
              </p>

              <p>
                <span class="font-semibold text-[#82e2ff]">NATIVO</span>
                {' '}O próprio jogo usa Steamworks; não precisa do Bridge
              </p>

              <p>
                <span class="font-semibold text-[#ffca85]">SÓ DETECTA</span>
                {' '}O Bridge vê o evento, mas ainda não sincroniza sozinho
              </p>

              <p>
                <span class="font-semibold text-[#ffca85]">AGUARDA DADOS</span>
                {' '}Integração preparada; abra o jogo para criar o estado de conquistas
              </p>

              <p>
                <span class="font-semibold text-[#ffca85]">SEM CATÁLOGO</span>
                {' '}O provedor existe, mas a Steam não retornou conquistas
              </p>

              <p>
                <span class="font-semibold text-[#ff6767]">SEM SUPORTE</span>
                {' '}Provedor de conquistas ainda não implementado
              </p>
            </div>
          </>
        )}
      </Show>
    </section>
  )
}
