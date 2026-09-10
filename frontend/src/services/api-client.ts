import type {
  AchievementCatalogResponse,
  AchievementPreviewRequest,
  AchievementPreviewResponse,
  AchievementPreviewRollbackRequest,
  AchievementPreviewRollbackResponse,
  AchievementSyncRequest,
  AchievementSyncResponse,
  ApiErrorBody,
  GamesResponse,
  HealthResponse,
  PrepareGameSupportResponse,
  ShutdownResponse,
  StartMonitorRequest,
  StartMonitorResponse,
  StopMonitorResponse,
} from '@/types'

export class ApiRequestError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'ApiRequestError'
    this.status = status
    this.code = code
  }
}

export interface AchievementBridgeClientOptions {
  baseUrl?: string
  fetch?: typeof globalThis.fetch
}

export class AchievementBridgeClient {
  private readonly baseUrl: string
  private readonly fetcher: typeof globalThis.fetch

  constructor(options: AchievementBridgeClientOptions = {}) {
    this.baseUrl = (options.baseUrl ?? '/v1').replace(/\/$/, '')
    this.fetcher = options.fetch ?? globalThis.fetch.bind(globalThis)
  }

  health(signal?: AbortSignal) {
    return this.request<HealthResponse>('/health', { signal })
  }

  listGames(verifySchema = false, signal?: AbortSignal) {
    const query = verifySchema ? '?verify_schema=true' : ''
    return this.request<GamesResponse>(`/games${query}`, { signal })
  }

  listAchievements(appId: number, signal?: AbortSignal) {
    return this.request<AchievementCatalogResponse>(`/games/${appId}/achievements`, { signal })
  }

  prepareGameSupport(appId: number, signal?: AbortSignal) {
    return this.request<PrepareGameSupportResponse>(`/games/${appId}/support`, {
      method: 'POST',
      signal,
    })
  }

  previewAchievement(input: AchievementPreviewRequest, signal?: AbortSignal) {
    return this.request<AchievementPreviewResponse>('/achievement-previews', {
      method: 'POST',
      body: JSON.stringify(input),
      signal,
    })
  }

  rollbackAchievementPreview(
    input: AchievementPreviewRollbackRequest,
    signal?: AbortSignal,
  ) {
    return this.request<AchievementPreviewRollbackResponse>('/achievement-previews/rollback', {
      method: 'POST',
      body: JSON.stringify(input),
      signal,
    })
  }

  syncAchievement(input: AchievementSyncRequest, signal?: AbortSignal) {
    return this.request<AchievementSyncResponse>('/achievement-syncs', {
      method: 'POST',
      body: JSON.stringify(input),
      signal,
    })
  }

  startMonitor(input: StartMonitorRequest = {}, signal?: AbortSignal) {
    return this.request<StartMonitorResponse>('/monitor/start', {
      method: 'POST',
      body: JSON.stringify(input),
      signal,
    })
  }

  stopMonitor(signal?: AbortSignal) {
    return this.request<StopMonitorResponse>('/monitor/stop', {
      method: 'POST',
      signal,
    })
  }

  shutdown(signal?: AbortSignal) {
    return this.request<ShutdownResponse>('/shutdown', {
      method: 'POST',
      signal,
    })
  }

  private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    if (init.body && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json')
    }

    const response = await this.fetcher(`${this.baseUrl}${path}`, {
      ...init,
      headers,
    })

    if (!response.ok) {
      const fallback = {
        error: {
          code: 'http_error',
          message: `Achievement Bridge API returned HTTP ${response.status}`,
        },
      }
      const body = (await response.json().catch(() => fallback)) as ApiErrorBody
      throw new ApiRequestError(response.status, body.error.code, body.error.message)
    }

    return (await response.json()) as T
  }
}

export const api = new AchievementBridgeClient()
