import type { MonitorEvent } from '@/types'

export interface MonitorEventHandlers {
  onEvent: (event: MonitorEvent) => void
  onError?: (event: Event) => void
}

export function subscribeToMonitorEvents(
  handlers: MonitorEventHandlers,
  url = '/v1/monitor/events',
): () => void {
  const source = new EventSource(url)

  source.onmessage = (event) => {
    const line = JSON.parse(event.data) as MonitorEvent
    handlers.onEvent(line)
  }
  source.onerror = (event) => handlers.onError?.(event)

  return () => source.close()
}
