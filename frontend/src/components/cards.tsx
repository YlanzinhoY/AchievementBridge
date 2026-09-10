import { A } from '@solidjs/router'
import { createMemo, createSignal, Show } from 'solid-js'


import { api } from '@/services/api-client'
import { createBridgeDashboard } from '@/stores/bridge-dashboard'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

export function BridgeCards() {
  const dashboard = createBridgeDashboard()
  const [controlAction, setControlAction] = createSignal<
    'idle' | 'starting' | 'stopping' | 'error'
  >('idle')

  const isMonitoring = createMemo(() => dashboard.health()?.core.monitoring ?? false)
  const isStopping = createMemo(() => dashboard.health()?.core.stopping ?? false)

  const status = createMemo(() => {
    if (dashboard.health.error) {
      return { label: 'Offline', description: 'A API local não respondeu', color: 'bg-red-500' }
    }

    if (dashboard.health.loading && !dashboard.health()) {
      return { label: 'Verificando', description: 'Consultando a API local', color: 'bg-amber-400' }
    }

    if (isStopping()) {
      return { label: 'Parando', description: 'Encerrando os observadores ativos', color: 'bg-amber-400' }
    }

    if (isMonitoring()) {
      return { label: 'Monitorando', description: 'Acompanhando conquistas em tempo real', color: 'bg-green-500' }
    }

    return { label: 'Pronto', description: 'Bridge conectado e aguardando início', color: 'bg-sky-500' }
  })

  async function startBridge() {
    if (controlAction() !== 'idle' || isMonitoring() || isStopping()) {
      return
    }

    setControlAction('starting')
    try {
      // Web mode already has one persistent, branded tray owner. Provider
      // balloons create one generic Windows tray icon per watcher, so keep
      // them disabled here while native Steam toasts remain available.
      await api.startMonitor({ notifications: false, native_toast: true })
      await dashboard.refresh()
    } catch {
      setControlAction('error')
      return
    }
    setControlAction('idle')
  }

  async function stopBridge() {
    if (controlAction() !== 'idle' || !isMonitoring()) {
      return
    }

    setControlAction('stopping')
    try {
      await api.stopMonitor()
      await dashboard.refresh()
    } catch {
      setControlAction('error')
      return
    }
    setControlAction('idle')
  }

  return (
    <section
      aria-label="Visão geral do Achievement Bridge"
      class="mx-auto grid w-full max-w-7xl grid-cols-[repeat(auto-fit,minmax(min(100%,18rem),1fr))] gap-3 px-4 py-8 sm:px-6 lg:px-8"
    >

      <A href="/jogos-compativeis" class="min-w-0 rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">

        <Card class="h-full min-w-0 cursor-pointer border-primary/25 bg-card transition hover:-translate-y-0.5 hover:border-primary/60 hover:bg-accent/40 hover:shadow-[0_12px_40px_rgba(162,119,255,0.12)]" >
          <CardHeader>
            <CardDescription>Biblioteca Steam</CardDescription>
            <CardTitle>Ver jogos compatíveis</CardTitle>
          </CardHeader>
          <CardContent>
            <Show
              when={!dashboard.games.loading || dashboard.games()}
              fallback={<span class="text-sm text-muted-foreground">Analisando jogos…</span>}
            >
              <Show
                when={!dashboard.games.error}
                fallback={<span class="text-sm text-destructive">Não foi possível consultar</span>}
              >
                <strong class="text-2xl text-primary">{dashboard.installedGameCount()}</strong>
                <span class="ml-2 text-sm text-muted-foreground">jogos encontrados</span>
              </Show>
            </Show>
          </CardContent>
        </Card>
      </A>

      <A href="/conquistas" class="min-w-0 rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
        <Card class="h-full min-w-0 cursor-pointer border-primary/25 bg-card transition hover:-translate-y-0.5 hover:border-primary/60 hover:bg-accent/40 hover:shadow-[0_12px_40px_rgba(162,119,255,0.12)]">
          <CardHeader>
            <CardDescription>Catálogos detectados</CardDescription>
            <CardTitle>Ver conquistas disponíveis</CardTitle>
          </CardHeader>
          <CardContent>
            <Show
              when={!dashboard.games.loading || dashboard.games()}
              fallback={<span class="text-sm text-muted-foreground">Contando conquistas…</span>}
            >
              <Show
                when={!dashboard.games.error}
                fallback={<span class="text-sm text-destructive">Não foi possível consultar</span>}
              >
                <strong class="text-2xl text-[#61ffca]">{dashboard.catalogGameCount()}</strong>
                <span class="ml-2 text-sm text-muted-foreground">catálogos disponíveis</span>
              </Show>
            </Show>
          </CardContent>
        </Card>
      </A>

      <Card class="h-full min-w-0 border-primary/25 bg-card">
        <CardHeader>
          <CardDescription>Controle do serviço</CardDescription>
          <CardTitle>Bridge</CardTitle>
        </CardHeader>
        <CardContent>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              disabled={controlAction() !== 'idle' || isMonitoring() || isStopping() || Boolean(dashboard.health.error)}
              onClick={() => void startBridge()}
              class="inline-flex h-9 items-center justify-center rounded-md border border-[#61ffca]/40 bg-[#61ffca]/10 px-3 text-sm font-medium text-[#61ffca] transition-colors hover:bg-[#61ffca] hover:text-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-40"
            >
              Ativar
            </button>
            <button
              type="button"
              disabled={controlAction() !== 'idle' || !isMonitoring()}
              onClick={() => void stopBridge()}
              class="inline-flex h-9 items-center justify-center rounded-md border border-destructive/45 bg-destructive/10 px-3 text-sm font-medium text-destructive transition-colors hover:bg-destructive hover:text-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-40"
            >
              Desativar
            </button>
          </div>
          <p class="mt-3 text-sm text-muted-foreground">
            <Show when={controlAction() === 'starting'}>Ativando os observadores…</Show>
            <Show when={controlAction() === 'stopping'}>Desativando os observadores…</Show>
            <Show when={controlAction() === 'error'}>
              Não foi possível concluir a ação. Tente novamente.
            </Show>
            <Show when={controlAction() === 'idle' && isMonitoring()}>
              Monitoramento ativo.
            </Show>
            <Show when={controlAction() === 'idle' && isStopping()}>
              Aguardando os observadores finalizarem…
            </Show>
            <Show when={controlAction() === 'idle' && !isMonitoring() && !isStopping() && !dashboard.health.error}>
              Pronto para monitorar suas conquistas.
            </Show>
            <Show when={controlAction() === 'idle' && dashboard.health.error}>
              Conecte a API local para controlar o Bridge.
            </Show>
          </p>
        </CardContent>
      </Card>

      <Card class="h-full min-w-0 border-primary/25 bg-card">
        <CardHeader>
          <CardDescription>Conexão local</CardDescription>
          <CardTitle>Status</CardTitle>
        </CardHeader>
        <CardContent>
          <div class="flex items-center gap-2">
            <span
              aria-hidden="true"
              class={`size-2.5 rounded-full ${status().color}`}
            />
            <strong>{status().label}</strong>
          </div>
          <p class="mt-2 text-sm text-muted-foreground">{status().description}</p>
          <Show when={dashboard.health.error}>
            <button
              type="button"
              onClick={() => void dashboard.refresh()}
              class="mt-3 text-sm font-medium underline underline-offset-4"
            >
              Tentar novamente
            </button>
          </Show>
        </CardContent>
      </Card>

    </section>
  )
}
