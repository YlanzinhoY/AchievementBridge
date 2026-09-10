import { createMemo, createResource, onCleanup } from 'solid-js'

import { api } from '@/services/api-client'

const HEALTH_REFRESH_INTERVAL_MS = 5_000

const bridgeSupportedStatuses = new Set([
  'COMPLETO',
  'AGUARDA DADOS',
  'SEM CATÁLOGO',
  'SÓ DETECTA',
])

export function createBridgeDashboard() {
  const [health, { refetch: refetchHealth }] = createResource(() => api.health())
  const [games, { refetch: refetchGames }] = createResource(() => api.listGames())

  const compatibleGameCount = createMemo(
    () => games()?.games.filter((game) => bridgeSupportedStatuses.has(game.status)).length ?? 0,
  )

  const installedGameCount = createMemo(() => games()?.games.length ?? 0)

  const achievementCount = createMemo(() =>
    games()?.games.reduce((total, game) => total + (game.achievement_count ?? 0), 0) ?? 0,
  )

  const healthTimer = window.setInterval(() => {
    void refetchHealth()
  }, HEALTH_REFRESH_INTERVAL_MS)

  onCleanup(() => window.clearInterval(healthTimer))

  return {
    achievementCount,
    compatibleGameCount,
    games,
    health,
    installedGameCount,
    refresh: () => Promise.all([refetchHealth(), refetchGames()]),
  }
}
