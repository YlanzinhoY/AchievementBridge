package monitor

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/events"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/games"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/providers"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/support"
)

type Options struct {
	SteamRoot     string
	SupportRoot   string
	JournalPath   string
	Interval      time.Duration
	SessionScan   time.Duration
	FinalGrace    time.Duration
	Recover       bool
	Broker        *events.Broker
	NativeSampler providers.NativeSampler
	OnAchievement func(providers.Event)
	Catalog       *games.Catalog
	ProcessLister func() ([]games.Process, error)
	Factories     []providers.Factory
}

type Status struct {
	Running        bool `json:"running"`
	ActiveSessions int  `json:"active_sessions"`
}

type Manager struct {
	options   Options
	catalog   games.Catalog
	journal   *Journal
	factories map[string]providers.Factory
	support   map[uint32]support.Manifest
	processes func() ([]games.Process, error)

	mu              sync.RWMutex
	running         bool
	cancel          context.CancelFunc
	done            chan struct{}
	sessions        map[uint32]*session
	lastActiveCount int
}

type session struct {
	game          providers.Game
	confidence    uint8
	pids          map[uint32]struct{}
	watcher       providers.Watcher
	state         providers.Snapshot
	stateLoaded   bool
	startedNoData bool
	closingAt     time.Time
	lastError     string
}

func New(options Options) (*Manager, error) {
	if options.Interval <= 0 {
		options.Interval = 500 * time.Millisecond
	}
	if options.SessionScan <= 0 {
		options.SessionScan = time.Second
	}
	if options.FinalGrace <= 0 {
		options.FinalGrace = 3 * time.Second
	}
	if options.SupportRoot == "" {
		options.SupportRoot = support.DefaultRoot()
	}
	if options.JournalPath == "" {
		options.JournalPath = filepath.Join(os.Getenv("LOCALAPPDATA"), "AchievementBridge", "journal.jsonl")
	}
	var catalog games.Catalog
	if options.Catalog != nil {
		catalog = *options.Catalog
	} else {
		var err error
		catalog, err = games.Discover(options.SteamRoot)
		if err != nil {
			return nil, err
		}
	}
	journal, err := OpenJournal(options.JournalPath)
	if err != nil {
		return nil, err
	}
	factories := options.Factories
	if factories == nil {
		factories = []providers.Factory{
			providers.GSEFactory{},
			providers.RUNEFactory{},
			providers.RockstarFactory{NativeSample: options.NativeSampler},
			providers.UbisoftFactory{},
			providers.UplayR2Factory{},
		}
	}
	processLister := options.ProcessLister
	if processLister == nil {
		processLister = games.ListProcesses
	}
	manager := &Manager{
		options:         options,
		catalog:         catalog,
		journal:         journal,
		factories:       make(map[string]providers.Factory, len(factories)),
		support:         support.LoadAll(options.SupportRoot),
		sessions:        make(map[uint32]*session),
		processes:       processLister,
		lastActiveCount: -1,
	}
	for _, factory := range factories {
		manager.factories[factory.Provider()] = factory
	}
	return manager, nil
}

func (m *Manager) Start() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running {
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.done = make(chan struct{})
	m.running = true
	go m.run(ctx)
	return nil
}

func (m *Manager) Stop(ctx context.Context) error {
	m.mu.Lock()
	if !m.running {
		m.mu.Unlock()
		return nil
	}
	cancel, done := m.cancel, m.done
	m.mu.Unlock()
	cancel()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *Manager) Status() Status {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return Status{Running: m.running, ActiveSessions: len(m.sessions)}
}

func (m *Manager) run(ctx context.Context) {
	defer func() {
		m.mu.Lock()
		remaining := make([]*session, 0, len(m.sessions))
		for _, active := range m.sessions {
			remaining = append(remaining, active)
		}
		m.sessions = make(map[uint32]*session)
		m.running = false
		m.mu.Unlock()
		for _, active := range remaining {
			_ = active.watcher.Close()
		}
		close(m.done)
	}()
	m.publish("[AchievementBridge] orchestrator=go mode=session-scoped status=watching")
	sessionTicker := time.NewTicker(m.options.SessionScan)
	providerTicker := time.NewTicker(m.options.Interval)
	defer sessionTicker.Stop()
	defer providerTicker.Stop()
	m.refreshSessions(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-sessionTicker.C:
			m.refreshSessions(ctx)
		case <-providerTicker.C:
			m.pollProviders(ctx)
		}
	}
}

func (m *Manager) refreshSessions(ctx context.Context) {
	m.support = support.LoadAll(m.options.SupportRoot)
	processes, err := m.processes()
	if err != nil {
		m.publish(fmt.Sprintf("[GameSession] discovery_error=%v", err))
		return
	}
	seen := make(map[uint32]map[uint32]struct{})
	for _, process := range processes {
		installed, found := m.catalog.FindByExecutable(process.ExecutablePath)
		if !found {
			continue
		}
		if seen[installed.AppID] == nil {
			seen[installed.AppID] = make(map[uint32]struct{})
		}
		seen[installed.AppID][process.PID] = struct{}{}
	}

	newSessions := make([]*session, 0)
	m.mu.Lock()
	for appID, pids := range seen {
		if active := m.sessions[appID]; active != nil {
			active.pids = pids
			active.closingAt = time.Time{}
			continue
		}
		installed := findInstalled(m.catalog.Apps, appID)
		provider, confidence, game, ok := m.resolveGame(installed)
		if !ok {
			continue
		}
		factory := m.factories[provider]
		watcher, openErr := factory.Open(game)
		if openErr != nil {
			m.publish(fmt.Sprintf("[GameSession] appid=%d provider=%s state=unsupported reason=%v", appID, provider, openErr))
			continue
		}
		active := &session{game: game, confidence: confidence, pids: pids, watcher: watcher}
		m.sessions[appID] = active
		m.publish(fmt.Sprintf("[GameSession] appid=%d name=%s state=watching", appID, game.Name))
		m.publish(fmt.Sprintf("  provider=%s confidence=%d active=true lifecycle=session", provider, confidence))
		newSessions = append(newSessions, active)
	}
	for appID, active := range m.sessions {
		if _, exists := seen[appID]; exists {
			continue
		}
		if active.closingAt.IsZero() {
			active.closingAt = time.Now().Add(m.options.FinalGrace)
			m.publish(fmt.Sprintf("[GameSession] appid=%d state=closing final_poll=true", appID))
		}
	}
	count := len(m.sessions)
	countChanged := count != m.lastActiveCount
	if countChanged {
		m.lastActiveCount = count
	}
	m.mu.Unlock()
	for _, active := range newSessions {
		m.initialSnapshot(ctx, active)
	}
	if countChanged {
		m.publish(fmt.Sprintf("[AchievementBridge] active_game_sessions=%d", count))
	}
}

func (m *Manager) resolveGame(installed games.Installed) (string, uint8, providers.Game, bool) {
	game := providers.Game{AppID: installed.AppID, Name: installed.Name, InstallDir: installed.InstallDir}
	if manifest, exists := m.support[installed.AppID]; exists {
		game.Provider = strings.ToLower(manifest.Provider)
		game.ProviderProductID = manifest.ProviderProduct
		game.SourceState = manifest.SourceState
		if factory := m.factories[game.Provider]; factory != nil {
			return game.Provider, 100, game, true
		}
	}
	for _, runtime := range games.DetectRuntime(installed) {
		if runtime.Confidence < 60 || m.factories[runtime.Provider] == nil {
			continue
		}
		game.Provider = runtime.Provider
		return runtime.Provider, runtime.Confidence, game, true
	}
	return "", 0, game, false
}

func (m *Manager) initialSnapshot(ctx context.Context, active *session) {
	snapshotCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	state, err := active.watcher.Snapshot(snapshotCtx)
	if errors.Is(err, providers.ErrStateUnavailable) {
		active.startedNoData = true
		m.publish(fmt.Sprintf("[%sProvider] appid=%d status=waiting source=session", providerLabel(active.game.Provider), active.game.AppID))
		return
	}
	if err != nil {
		active.lastError = err.Error()
		m.publish(fmt.Sprintf("[%sProvider] appid=%d snapshot_error=%v", providerLabel(active.game.Provider), active.game.AppID, err))
		return
	}
	m.adoptInitialState(active, state, false)
	m.publish(fmt.Sprintf("[%sProvider] appid=%d status=watching unlocked=%d source=session", providerLabel(active.game.Provider), active.game.AppID, unlockedCount(state)))
}

func (m *Manager) adoptInitialState(active *session, state providers.Snapshot, liveFirstSnapshot bool) {
	if liveFirstSnapshot {
		_ = m.journal.MarkGame(active.game.Provider, active.game.AppID)
		m.emitUnseen(active, state, false)
	} else if !m.journal.HasGame(active.game.Provider, active.game.AppID) {
		if err := m.journal.Baseline(active.game.Provider, active.game.AppID, state); err != nil {
			log.Printf("provider baseline failed: %v", err)
		}
		_ = m.journal.MarkGame(active.game.Provider, active.game.AppID)
	} else if m.options.Recover {
		m.emitUnseen(active, state, true)
	}
	active.state, active.stateLoaded = state, true
}

func (m *Manager) pollProviders(ctx context.Context) {
	m.mu.RLock()
	now := time.Now()
	appIDs := make([]uint32, 0, len(m.sessions))
	sessions := make(map[uint32]*session, len(m.sessions))
	for appID := range m.sessions {
		appIDs = append(appIDs, appID)
		sessions[appID] = m.sessions[appID]
	}
	m.mu.RUnlock()
	sort.Slice(appIDs, func(i, j int) bool { return appIDs[i] < appIDs[j] })
	for _, appID := range appIDs {
		active := sessions[appID]
		m.pollSession(ctx, active)
		if !active.closingAt.IsZero() && !now.Before(active.closingAt) {
			_ = active.watcher.Close()
			m.mu.Lock()
			if m.sessions[appID] == active {
				delete(m.sessions, appID)
			}
			m.mu.Unlock()
			m.publish(fmt.Sprintf("[GameSession] appid=%d state=finished", appID))
		}
	}
}

func (m *Manager) pollSession(ctx context.Context, active *session) {
	snapshotCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	state, err := active.watcher.Snapshot(snapshotCtx)
	if errors.Is(err, providers.ErrStateUnavailable) {
		return
	}
	if err != nil {
		if active.lastError != err.Error() {
			active.lastError = err.Error()
			m.publish(fmt.Sprintf("[%sProvider] appid=%d snapshot_error=%v", providerLabel(active.game.Provider), active.game.AppID, err))
		}
		return
	}
	active.lastError = ""
	if !active.stateLoaded {
		m.adoptInitialState(active, state, active.startedNoData)
		m.publish(fmt.Sprintf("[%sProvider] appid=%d status=watching unlocked=%d source=session", providerLabel(active.game.Provider), active.game.AppID, unlockedCount(state)))
		return
	}
	for _, found := range providers.Diff(active.state, state) {
		found.AppID = active.game.AppID
		found.Provider = active.game.Provider
		found.DetectedAt = time.Now()
		m.emit(found)
	}
	active.state = state
}

func (m *Manager) emitUnseen(active *session, state providers.Snapshot, recovered bool) {
	for id, achievement := range state {
		if !achievement.Unlocked || m.journal.HasEvent(active.game.Provider, active.game.AppID, id) {
			continue
		}
		m.emit(providers.Event{
			AppID: active.game.AppID, Provider: active.game.Provider, Achievement: id,
			Timestamp: achievement.Timestamp, DetectedAt: time.Now(), Recovered: recovered,
		})
	}
}

func (m *Manager) emit(event providers.Event) {
	recorded, err := m.journal.Record(event)
	if err != nil {
		m.publish(fmt.Sprintf("[AchievementBridge] journal_error=%v", err))
		return
	}
	if !recorded {
		return
	}
	m.publish("[AchievementBridge]")
	m.publish("provider=" + event.Provider)
	m.publish(fmt.Sprintf("appid=%d", event.AppID))
	m.publish("achievement=" + event.Achievement)
	m.publish("state=unlocked")
	m.publish(fmt.Sprintf("timestamp=%d", event.Timestamp))
	m.publish(fmt.Sprintf("recovered=%t", event.Recovered))
	m.publish("")
	if m.options.OnAchievement != nil && syncProvider(event.Provider) {
		m.options.OnAchievement(event)
	}
}

func (m *Manager) publish(line string) {
	if m.options.Broker != nil {
		m.options.Broker.Publish(line)
	}
	log.Print(line)
}

func findInstalled(apps []games.Installed, appID uint32) games.Installed {
	for _, app := range apps {
		if app.AppID == appID {
			return app
		}
	}
	return games.Installed{AppID: appID}
}

func unlockedCount(state providers.Snapshot) int {
	count := 0
	for _, achievement := range state {
		if achievement.Unlocked {
			count++
		}
	}
	return count
}

func providerLabel(provider string) string {
	switch provider {
	case "gse":
		return "GSE"
	case "rune":
		return "Rune"
	case "rockstar":
		return "Rockstar"
	case "ubisoft":
		return "Ubisoft"
	case "uplay_r2":
		return "UplayR2"
	default:
		return provider
	}
}

func syncProvider(provider string) bool {
	switch provider {
	case "gse", "rune", "rockstar", "uplay_r2":
		return true
	default:
		return false
	}
}
