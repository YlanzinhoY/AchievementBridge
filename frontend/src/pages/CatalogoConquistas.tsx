import { A, useParams } from '@solidjs/router'
import { createMemo, createResource, For, Show } from 'solid-js'

import { api } from '@/services/api-client'
import type { Achievement } from '@/types'

function formatRarity(percent: number | null) {
  return percent === null ? '—' : `${percent.toFixed(1)}% global`
}

function formatUnlockTime(timestamp: number) {
  if (!timestamp) {
    return null
  }
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(timestamp * 1_000))
}

function achievementState(achievement: Achievement) {
  return achievement.unlocked ? 'Obtida' : 'Bloqueada'
}

export default function CatalogoConquistas() {
  const params = useParams<{ appId: string }>()
  const appId = createMemo(() => {
    const value = Number(params.appId)
    return Number.isSafeInteger(value) && value > 0 ? value : null
  })
  const [catalog] = createResource(appId, (id) => api.listAchievements(id))
  const [games] = createResource(() => api.listGames(true))
  const gameName = createMemo(
    () => games()?.games.find((game) => game.app_id === appId())?.name ?? null,
  )
  const unlockedCount = createMemo(
    () => catalog()?.achievements.filter((achievement) => achievement.unlocked).length ?? 0,
  )

  return (
    <section class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
      <A
        href="/conquistas"
        class="inline-flex text-sm font-medium text-primary underline-offset-4 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        ← Todos os jogos
      </A>

      <Show
        when={appId()}
        fallback={
          <p class="mt-6 rounded-lg border border-destructive/40 bg-destructive/10 p-4 text-destructive">
            AppID inválido.
          </p>
        }
      >
        <Show when={catalog.loading}>
          <p class="mt-6 text-sm text-primary">Carregando o catálogo de conquistas...</p>
        </Show>

        <Show when={catalog.error}>
          <p class="mt-6 rounded-lg border border-destructive/40 bg-destructive/10 p-4 text-destructive">
            Não foi possível carregar as conquistas: {catalog.error?.message}
          </p>
        </Show>

        <Show when={catalog()}>
          {(data) => (
            <>
              <header class="mt-6 border-b border-primary/25 pb-6">
                <p class="text-sm font-medium text-primary">AppID {data().app_id}</p>
                <h1 class="mt-1 text-2xl font-bold tracking-tight sm:text-3xl">
                  {gameName() ?? 'Conquistas disponíveis'}
                </h1>
                <p class="mt-2 text-sm text-muted-foreground">
                  {unlockedCount()} de {data().achievements.length} obtidas nesta instalação.
                </p>
              </header>

              <div class="mt-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                <For each={data().achievements}>
                  {(achievement) => {
                    const image = () => (
                      achievement.unlocked ? achievement.icon : achievement.icon_gray || achievement.icon
                    )
                    const unlockTime = () => formatUnlockTime(achievement.unlock_time)

                    return (
                      <article
                        class={`min-w-0 rounded-lg border p-4 transition ${
                          achievement.unlocked
                            ? 'border-[#61ffca]/45 bg-[#61ffca]/[0.06]'
                            : 'border-primary/20 bg-card'
                        }`}
                      >
                        <div class="flex gap-4">
                          <div class="grid size-16 shrink-0 place-items-center overflow-hidden rounded-md border border-primary/20 bg-muted/40">
                            <Show
                              when={image()}
                              fallback={<span class="text-xs text-muted-foreground">—</span>}
                            >
                              <img
                                src={image()}
                                alt=""
                                class={`size-full object-cover ${achievement.unlocked ? '' : 'opacity-55 grayscale'}`}
                              />
                            </Show>
                          </div>

                          <div class="min-w-0 flex-1">
                            <div class="flex items-start justify-between gap-3">
                              <h2 class="font-semibold leading-snug">{achievement.name}</h2>
                              <span
                                class={`shrink-0 text-xs font-semibold ${
                                  achievement.unlocked ? 'text-[#61ffca]' : 'text-muted-foreground'
                                }`}
                              >
                                {achievementState(achievement)}
                              </span>
                            </div>
                            <p class="mt-1 text-sm leading-relaxed text-muted-foreground">
                              {achievement.hidden && !achievement.unlocked
                                ? 'Conquista secreta'
                                : achievement.description || 'Sem descrição disponível.'}
                            </p>
                          </div>
                        </div>

                        <div class="mt-4 border-t border-border/70 pt-3 text-xs text-muted-foreground">
                          <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                            <span>{formatRarity(achievement.global_percent)}</span>
                            <Show when={unlockTime()}>{(time) => <span>Obtida em {time()}</span>}</Show>
                          </div>
                          <p class="mt-2 truncate font-mono text-[11px]" title={achievement.api_name}>
                            {achievement.api_name}
                          </p>
                        </div>
                      </article>
                    )
                  }}
                </For>
              </div>
            </>
          )}
        </Show>
      </Show>
    </section>
  )
}
