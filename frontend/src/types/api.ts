export type Provider =
  | 'none'
  | 'steam'
  | 'gse'
  | 'rune'
  | 'rockstar'
  | 'ubisoft'
  | 'uplay_r2'
  | 'epic'
  | 'gog'
  | 'ea'
  | 'xbox'

export type GameSupportStatus =
  | 'COMPLETO'
  | 'AGUARDA DADOS'
  | 'SEM CATÁLOGO'
  | 'SÓ DETECTA'
  | 'NATIVO'
  | 'SEM SUPORTE'

export interface ApiErrorBody {
  error: {
    code: string
    message: string
  }
}

export interface CoreHealth {
  service: 'achievement-bridge-core' | 'achievement-bridge-native-core'
  status: 'ready' | 'idle'
  protocol_version: number
  steam_session_scope: 'request'
  monitoring: boolean
  stopping: boolean
}

export interface MonitorHealth {
  running: boolean
  active_sessions: number
}

export interface HealthResponse {
  service: 'achievement-bridge-api'
  status: 'ready'
  core: CoreHealth
  monitor: MonitorHealth
  web_ui: boolean
}

export interface GameSupport {
  app_id: number
  name: string
  directory: string
  provider: Provider
  confidence: number
  achievement_count: number | null
  state_available: boolean
  status: GameSupportStatus
}

export interface GamesResponse {
  games: GameSupport[]
}

export interface Achievement {
  api_name: string
  name: string
  description: string
  icon: string
  icon_gray: string
  unlocked: boolean
  unlock_time: number
  hidden: boolean
  global_percent: number | null
}

export interface AchievementCatalogResponse {
  app_id: number
  achievements: Achievement[]
}

export interface PrepareGameSupportResponse {
  app_id: number
  game: string
  provider: 'uplay_r2'
  provider_product_id: number | null
  achievement_count: number
  schema_path: string
  config_path: string
  manifest_path: string
  status: 'COMPLETO' | 'AGUARDA DADOS'
}

export interface AchievementPreviewRequest {
  app_id: number
  achievement: string
  duration_ms?: number
  wait_for_game_dir?: string
}

export interface AchievementPreviewResponse {
  app_id: number
  achievement: string
  name: string
  preview_mode: 'bridge_notification'
  native_unlock_toast: false
  steam_state_changed: false
  state_after: 'locked' | 'unlocked'
}

export interface AchievementPreviewRollbackRequest {
  app_id: number
  achievement: string
}

export interface AchievementPreviewRollbackResponse {
  app_id: number
  achievement: string
  preview_state_changed: false
  rollback_required: false
  state_after: 'unchanged'
}

export interface AchievementSyncRequest {
  app_id: number
  achievement: string
  provider: Extract<Provider, 'gse' | 'rune' | 'rockstar' | 'uplay_r2'>
  timestamp?: number
  native_toast?: boolean
}

export type NativeNotificationStatus =
  | 'not_requested'
  | 'not_new'
  | 'progress_queued'
  | 'steam_unavailable'
  | 'progress_failed'
  | 'sync_unconfirmed'

export interface SteamLocalProjectionSyncResponse {
  app_id: number
  achievement: string
  provider: AchievementSyncRequest['provider']
  route: 'steam_local_projection'
  server_request: false
  changed: boolean
  projection_confirmed: boolean
  host_status: 'captured' | 'unavailable' | 'app_not_managed' | 'stats_sync_disabled' | 'rejected'
  stat_id: number
  bit: number
  permission: number
  native_notification: NativeNotificationStatus
}

export type AchievementSyncResponse = SteamLocalProjectionSyncResponse

export interface StartMonitorRequest {
  interval_ms?: number
  journal_path?: string
  recover?: boolean
  notifications?: boolean
  native_toast?: boolean
}

export interface StartMonitorResponse {
  monitoring: boolean
  interval_ms?: number
  orchestrator?: 'go'
  scope?: 'active_game_sessions'
  final_poll_grace_ms?: number
}

export interface StopMonitorResponse {
  monitoring: false
  stopping: boolean
}

export interface ShutdownResponse {
  status: 'shutting_down'
}

export type MonitorEvent = string
