import { A } from '@solidjs/router'
import { createResource, For, Show } from 'solid-js'

import { api } from '@/services/api-client'

const catalogStatuses = new Set(['COMPLETO', 'NATIVO', 'SÓ DETECTA', 'AGUARDA DADOS'])

export default function ConquistasDisponiveis() {
  const [games] = createResource(() => api.listGames(true))

  return (
    <section class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
      <div class="mb-6">
        <p class="text-sm font-medium text-primary">Catálogos Steam</p>
        <h1 class="mt-1 text-2xl font-bold tracking-tight sm:text-3xl">
          Conquistas disponíveis
        </h1>
        <p class="mt-2 text-sm text-muted-foreground">
          Escolha um jogo para consultar suas conquistas, progresso e raridade global.
        </p>
      </div>

      <Show when={games.loading}>
        <p class="text-sm text-primary">Carregando os catálogos de conquistas...</p>
      </Show>

      <Show when={games.error}>
        <p class="rounded-lg border border-destructive/40 bg-destructive/10 p-4 text-destructive">
          Não foi possível carregar os jogos: {games.error?.message}
        </p>
      </Show>

      <Show when={games()}>
        {(data) => {
          const catalogGames = () => data().games.filter((game) => catalogStatuses.has(game.status))

          return (
            <Show
              when={catalogGames().length > 0}
              fallback={
                <p class="rounded-lg border border-primary/25 bg-card p-5 text-sm text-muted-foreground">
                  Nenhum catálogo de conquistas está disponível nesta biblioteca ainda.
                </p>
              }
            >
              <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                <For each={catalogGames()}>
                  {(game) => (
                    <A
                      href={`/conquistas/${game.app_id}`}
                      class="group rounded-lg border border-primary/25 bg-card p-5 transition hover:-translate-y-0.5 hover:border-primary/65 hover:bg-accent/35 hover:shadow-[0_12px_40px_rgba(162,119,255,0.12)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                    >
                      <p class="text-sm text-muted-foreground">{game.provider}</p>
                      <h2 class="mt-1 line-clamp-2 font-semibold leading-snug">{game.name}</h2>
                      <div class="mt-5 flex items-baseline justify-between gap-3">
                        <span class="text-sm font-medium text-[#61ffca]">
                          {game.achievement_count === null
                            ? 'Catálogo disponível'
                            : `${game.achievement_count} conquistas`}
                        </span>
                        <span class="text-sm font-medium text-primary group-hover:underline">
                          Ver catálogo
                        </span>
                      </div>
                    </A>
                  )}
                </For>
              </div>
            </Show>
          )
        }}
      </Show>
    </section>
  )
}
