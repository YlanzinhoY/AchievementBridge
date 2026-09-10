import { createSignal, For, onCleanup, onMount } from 'solid-js'

import { subscribeToMonitorEvents } from '@/services/monitor-events'
import type { MonitorEvent } from '@/types'

import {
  Card,
  CardContent,
  CardHeader,
} from '@/components/ui/card'

export default function Logs() {
  const [logs, setLogs] = createSignal<MonitorEvent[]>([])

  let terminalRef: HTMLDivElement | undefined
  let followLatest = true

  const scrollToBottom = (force = false) => {
    if (!force && !followLatest) {
      return
    }

    requestAnimationFrame(() => {
      if (terminalRef) {
        terminalRef.scrollTop = terminalRef.scrollHeight
      }
    })
  }

  const updateFollowLatest = (event: Event) => {
    const terminal = event.currentTarget as HTMLDivElement
    const distanceFromBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight
    followLatest = distanceFromBottom < 24
  }

  const unsubscribe = subscribeToMonitorEvents({
    onEvent: (event) => {
      setLogs((current) => {
        const last = current[current.length - 1]

        if (last === event) {
          return current
        }

        return [...current, event]
      })

      scrollToBottom()
    },

    onError: (error) => {
      console.error('Erro no stream de eventos:', error)
    },
  })

  onMount(() => scrollToBottom(true))
  onCleanup(unsubscribe)

  return (
    <section class="h-[calc(100svh-80px)] w-full bg-background">
      <Card
        class="
          flex
          h-full
          w-full
          flex-col
          overflow-hidden
          rounded-none
          border-0
          bg-background
          shadow-none
        "
      >
        {/* Barra superior */}
        <CardHeader
          class="
            shrink-0
            border-b
            border-primary/20
            bg-background
            px-6
            py-4
          "
        >
          <div class="relative flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="size-3 rounded-full bg-red-500" />
              <span class="size-3 rounded-full bg-yellow-400" />
              <span class="size-3 rounded-full bg-green-500" />
            </div>

            <div
              class="
                absolute
                left-1/2
                -translate-x-1/2
                font-console
                text-[16px]
                uppercase
                tracking-[0.12em]
                text-primary/60
              "
            >
              achievement-bridge
            </div>

            <div
              class="
                flex
                items-center
                gap-2
                font-console
                text-[16px]
                uppercase
                text-[#61ffca]
              "
            >
              <span
                class="
                  size-2
                  bg-[#61ffca]
                  shadow-[0_0_8px_rgba(97,255,202,0.8)]
                "
              />
              ativo
            </div>
          </div>
        </CardHeader>

        <CardContent class="flex min-h-0 flex-1 flex-col bg-background p-0">
          <div
            ref={terminalRef}
            onScroll={updateFollowLatest}
            class="
              relative
              min-h-0
              flex-1
              overflow-auto
              bg-background
              font-console
              text-[18px]
              leading-[1.35]
              tracking-[0.01em]
              text-foreground
            "
          >
            {/* scanlines */}
            <div
              aria-hidden="true"
              class="
                pointer-events-none
                absolute
                inset-0
                z-10
                opacity-[0.025]
                [background:repeating-linear-gradient(0deg,transparent,transparent_2px,#ffffff_3px)]
              "
            />

            <div
              class="
                border-b
                border-primary/30
                bg-background
                px-8
                py-6
              "
            >
              <div class="flex flex-wrap items-center gap-x-2">
                <span
                  class="
                    text-[#61ffca]
                    drop-shadow-[0_0_5px_rgba(97,255,202,0.35)]
                  "
                >
                  Bridge ativado.
                </span>

                <span class="text-foreground">
                  Abra seu jogo normalmente.
                </span>
              </div>

              <div class="mt-2 text-muted-foreground">
                Os eventos aparecerão abaixo. Pressione Ctrl+C para voltar ao
                menu; o Bridge continuará ativo.
              </div>
            </div>

            {/* Logs */}
            <div class="relative z-20 min-w-max px-8 py-6">
              <For each={logs()}>
                {(log) => (
                  <div
                    class="
                      flex
                      min-w-max
                      items-start
                      gap-4
                      px-1
                      py-[2px]
                      hover:bg-primary/5
                    "
                  >
                    <span class="select-none text-primary">
                      &gt;
                    </span>

                    <span class="whitespace-pre text-foreground">
                      {log}
                    </span>
                  </div>
                )}
              </For>

              {logs().length === 0 && (
                <div class="flex items-center gap-4 px-1 text-muted-foreground">
                  <span class="text-primary">&gt;</span>
                  <span>aguardando eventos</span>
                  <span class="animate-pulse text-[#61ffca]">█</span>
                </div>
              )}
            </div>
          </div>

          {/* Footer */}
          <div
            class="
              flex
              shrink-0
              items-center
              justify-between
              border-t
              border-primary/20
              bg-background
              px-8
              py-3
              font-console
              text-[14px]
              uppercase
              tracking-wider
              text-muted-foreground
            "
          >
            <div class="flex items-center gap-4">
              <span>eventos: {logs().length}</span>
              <span class="text-primary/25">|</span>
            </div>

            <div class="flex items-center gap-2 text-[#61ffca]">
              <span
                class="
                  size-2
                bg-[#61ffca]
                shadow-[0_0_6px_rgba(97,255,202,0.7)]
                "
              />
              stream conectado
            </div>
          </div>
        </CardContent>
      </Card>
    </section>
  )
}
