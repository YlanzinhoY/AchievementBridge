package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/core"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/events"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/games"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/gamestamp"
	monitoring "github.com/YlanzinhoY/AchievementBridge/api/internal/monitor"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/providers"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/support"
)

const (
	defaultAPIAddress   = "127.0.0.1:47650"
	defaultCoreAddress  = "127.0.0.1:47651"
	coreRecoveryTimeout = 15 * time.Second
)

type application struct {
	core       coreCaller
	supervisor coreSupervisor
	eventSync  *eventSyncer
	shutdown   func()
	webUI      bool
	steamRoot  string

	recoveryMu sync.Mutex
	monitorMu  sync.Mutex
	monitor    *monitoring.Manager
}

type coreCaller interface {
	Call(context.Context, string, any, any) error
}

type coreSupervisor interface {
	Ensure(context.Context) error
	Events() *events.Broker
}

type achievement struct {
	APIName       string   `json:"api_name"`
	Name          string   `json:"name"`
	Description   string   `json:"description"`
	Icon          string   `json:"icon"`
	IconGray      string   `json:"icon_gray"`
	Unlocked      bool     `json:"unlocked"`
	UnlockTime    int64    `json:"unlock_time"`
	Hidden        bool     `json:"hidden"`
	GlobalPercent *float32 `json:"global_percent"`
}

type achievementCatalog struct {
	AppID        uint32        `json:"app_id"`
	Achievements []achievement `json:"achievements"`
}

type gameSupport struct {
	AppID             uint32  `json:"app_id"`
	Name              string  `json:"name"`
	Directory         string  `json:"directory"`
	Provider          string  `json:"provider"`
	Confidence        uint8   `json:"confidence"`
	AchievementCount  *uint64 `json:"achievement_count"`
	StateAvailable    bool    `json:"state_available"`
	Status            string  `json:"status"`
	ProviderProductID *uint32 `json:"provider_product_id,omitempty"`
}

type previewRequest struct {
	AppID          uint32  `json:"app_id"`
	Achievement    string  `json:"achievement"`
	DurationMS     uint32  `json:"duration_ms"`
	WaitForGameDir *string `json:"wait_for_game_dir,omitempty"`
}

func main() {
	apiAddress := flag.String("listen", envOr("ACHIEVEMENT_BRIDGE_API_ADDRESS", defaultAPIAddress), "loopback HTTP address")
	coreAddress := flag.String("core-address", envOr("ACHIEVEMENT_BRIDGE_CORE_ADDRESS", defaultCoreAddress), "loopback Zig core address")
	coreExecutable := flag.String("core", os.Getenv("ACHIEVEMENT_BRIDGE_PATH"), "path to achievement-bridge executable")
	steamRoot := flag.String("steam-root", os.Getenv("STEAM_ROOT"), "optional Steam installation path")
	webRoot := flag.String("web-root", os.Getenv("ACHIEVEMENT_BRIDGE_WEB_ROOT"), "optional compiled Web UI directory")
	parentPID := flag.Int("parent-pid", 0, "optional UI process whose exit stops this API")
	flag.Parse()

	if err := requireLoopback(*apiAddress); err != nil {
		log.Fatal(err)
	}
	if err := requireLoopback(*coreAddress); err != nil {
		log.Fatal(err)
	}
	if *coreExecutable == "" {
		resolved, err := findCoreExecutable()
		if err != nil {
			log.Fatal(err)
		}
		*coreExecutable = resolved
	}

	coreClient := core.NewClient(*coreAddress)
	supervisor := core.NewSupervisor(coreClient, *coreExecutable, *coreAddress, *steamRoot)
	defer supervisor.Close()

	app := &application{
		core:       coreClient,
		supervisor: supervisor,
		steamRoot:  *steamRoot,
	}
	stampStore := gamestamp.New(gamestamp.DefaultRoot())
	if imported, err := stampStore.ImportJournal(gamestamp.DefaultJournalPath(), gamestamp.DefaultSupportRoot()); err != nil && !os.IsNotExist(err) {
		log.Printf("game stamp journal import failed: %v", err)
	} else if imported > 0 {
		log.Printf("game stamps loaded from journal achievements=%d", imported)
	}
	app.eventSync = newEventSyncer(app.callCore, stampStore)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", app.health)
	mux.HandleFunc("GET /v1/games", app.listGames)
	mux.HandleFunc("GET /v1/games/{app_id}/achievements", app.listAchievements)
	mux.HandleFunc("POST /v1/games/{app_id}/support", app.prepareGameSupport)
	mux.HandleFunc("POST /v1/achievement-previews", app.previewAchievement)
	mux.HandleFunc("POST /v1/achievement-previews/rollback", app.rollbackAchievementPreview)
	mux.HandleFunc("POST /v1/achievement-syncs", app.syncAchievement)
	mux.HandleFunc("POST /v1/monitor/start", app.startMonitor)
	mux.HandleFunc("POST /v1/monitor/stop", app.stopMonitor)
	mux.HandleFunc("GET /v1/monitor/events", app.monitorEvents)
	mux.HandleFunc("POST /v1/shutdown", app.shutdownAPI)
	if handler, err := webUIHandler(*webRoot); err != nil {
		log.Printf("Web UI disabled: %v", err)
	} else if handler != nil {
		mux.Handle("GET /", handler)
		app.webUI = true
		log.Printf("Web UI available from %s", *webRoot)
	}

	server := &http.Server{
		Addr:              *apiAddress,
		Handler:           requestLogger(mux),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	app.shutdown = func() {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = server.Shutdown(ctx)
		}()
	}
	if *parentPID > 0 {
		go func() {
			if err := waitForProcessExit(*parentPID); err != nil {
				log.Printf("parent process watcher stopped: %v", err)
			}
			app.shutdown()
		}()
	}
	shutdownContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdownContext.Done()
		app.stopGoMonitor()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	log.Printf("Achievement Bridge API ready at http://%s (core %s)", *apiAddress, *coreAddress)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (a *application) listGames(writer http.ResponseWriter, request *http.Request) {
	verifySchema, err := strconv.ParseBool(request.URL.Query().Get("verify_schema"))
	if err != nil && request.URL.Query().Has("verify_schema") {
		writeError(writer, http.StatusBadRequest, "invalid_verify_schema", "verify_schema must be true or false")
		return
	}
	catalog, err := games.Discover(a.steamRoot)
	if err != nil {
		writeError(writer, http.StatusServiceUnavailable, "steam_library_unavailable", err.Error())
		return
	}
	manifests := support.LoadAll(support.DefaultRoot())
	result := struct {
		Games []gameSupport `json:"games"`
	}{Games: make([]gameSupport, 0, len(catalog.Apps))}
	for _, installed := range catalog.Apps {
		report := gameSupport{
			AppID:     installed.AppID,
			Name:      installed.Name,
			Directory: installed.InstallDir,
			Provider:  "none",
			Status:    "SEM SUPORTE",
		}
		if manifest, found := manifests[installed.AppID]; found {
			report.Provider = strings.ToLower(manifest.Provider)
			report.Confidence = 100
			report.ProviderProductID = optionalUint32(manifest.ProviderProduct)
			report.AchievementCount = optionalUint64(manifest.CatalogCount)
			report.StateAvailable = manifest.SourceState != "" && fileExists(manifest.SourceState)
			if report.Provider == "uplay_r2" {
				if manifest.ProviderProduct != 0 && report.StateAvailable {
					report.Status = "COMPLETO"
				} else {
					report.Status = "AGUARDA DADOS"
				}
			}
		} else if runtime, found := selectGoProvider(games.DetectRuntime(installed)); found {
			report.Provider = runtime.Provider
			report.Confidence = runtime.Confidence
			report.StateAvailable = runtime.Provider != "rockstar" || installed.AppID == 3240220
			report.Status = classifyGameSupport(report.Provider, report.Confidence, report.StateAvailable)
		}
		if verifySchema && supportsGoSync(report.Provider, report.Confidence) && report.AchievementCount == nil {
			ctx, cancel := context.WithTimeout(request.Context(), 45*time.Second)
			var catalog achievementCatalog
			if err := a.callCore(ctx, "list_achievements", map[string]any{"app_id": installed.AppID}, &catalog); err == nil {
				count := uint64(len(catalog.Achievements))
				report.AchievementCount = &count
				if count == 0 {
					report.Status = "SEM CATÁLOGO"
				}
			}
			cancel()
		}
		result.Games = append(result.Games, report)
	}
	writeJSON(writer, http.StatusOK, result)
}

func selectGoProvider(runtimes []games.Runtime) (games.Runtime, bool) {
	for _, runtime := range runtimes {
		switch runtime.Provider {
		case "gse", "rune", "rockstar", "uplay_r2", "ubisoft", "steam":
			return runtime, true
		}
	}
	return games.Runtime{}, false
}

func supportsGoSync(provider string, confidence uint8) bool {
	return confidence >= 60 && (provider == "gse" || provider == "rune" || provider == "rockstar" || provider == "uplay_r2")
}

func classifyGameSupport(provider string, confidence uint8, stateAvailable bool) string {
	if supportsGoSync(provider, confidence) {
		if provider == "rockstar" && !stateAvailable {
			return "AGUARDA DADOS"
		}
		return "COMPLETO"
	}
	if confidence >= 60 && (provider == "ubisoft" || provider == "uplay_r2") {
		return "SÓ DETECTA"
	}
	if confidence >= 50 && provider == "steam" {
		return "NATIVO"
	}
	return "SEM SUPORTE"
}

func optionalUint32(value uint32) *uint32 {
	if value == 0 {
		return nil
	}
	copy := value
	return &copy
}

func optionalUint64(value uint64) *uint64 {
	if value == 0 {
		return nil
	}
	copy := value
	return &copy
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func (a *application) health(writer http.ResponseWriter, request *http.Request) {
	// The native Zig adapter is intentionally lazy in 0.3. Merely opening the
	// Web UI or polling health must not create another background process.
	ctx, cancel := context.WithTimeout(request.Context(), 500*time.Millisecond)
	defer cancel()
	coreHealth := map[string]any{
		"service":             "achievement-bridge-native-core",
		"status":              "idle",
		"monitoring":          false,
		"stopping":            false,
		"steam_session_scope": "request",
		"protocol_version":    1,
	}
	var runningCore map[string]any
	if err := a.core.Call(ctx, "health", struct{}{}, &runningCore); err == nil {
		coreHealth = runningCore
	}
	monitorStatus := monitoring.Status{}
	a.monitorMu.Lock()
	if a.monitor != nil {
		monitorStatus = a.monitor.Status()
	}
	a.monitorMu.Unlock()
	writeJSON(writer, http.StatusOK, map[string]any{
		"service": "achievement-bridge-api",
		"status":  "ready",
		"core":    coreHealth,
		"web_ui":  a.webUI,
		"monitor": monitorStatus,
	})
}

func (a *application) listAchievements(writer http.ResponseWriter, request *http.Request) {
	appID, err := strconv.ParseUint(request.PathValue("app_id"), 10, 32)
	if err != nil || appID == 0 {
		writeError(writer, http.StatusBadRequest, "invalid_app_id", "AppID must be a positive integer")
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 45*time.Second)
	defer cancel()
	var catalog achievementCatalog
	if err := a.callCore(ctx, "list_achievements", map[string]any{"app_id": appID}, &catalog); err != nil {
		writeCoreError(writer, err)
		return
	}
	normalizeAchievementImages(uint32(appID), &catalog)
	writeJSON(writer, http.StatusOK, catalog)
}

func normalizeAchievementImages(appID uint32, catalog *achievementCatalog) {
	for index := range catalog.Achievements {
		catalog.Achievements[index].Icon = steamAchievementImageURL(appID, catalog.Achievements[index].Icon)
		catalog.Achievements[index].IconGray = steamAchievementImageURL(appID, catalog.Achievements[index].IconGray)
	}
}

// The Zig core normally returns the absolute CDN URL. Keeping this adapter at
// the HTTP boundary preserves the public contract for older cores and for
// Steam clients that still return the original filename display attribute.
func steamAchievementImageURL(appID uint32, image string) string {
	image = strings.TrimSpace(image)
	if image == "" || strings.HasPrefix(image, "https://") || strings.HasPrefix(image, "http://") {
		return image
	}
	return fmt.Sprintf(
		"https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/%d/%s",
		appID,
		url.PathEscape(image),
	)
}

func (a *application) previewAchievement(writer http.ResponseWriter, request *http.Request) {
	var input previewRequest
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	input.Achievement = strings.TrimSpace(input.Achievement)
	if input.AppID == 0 || input.Achievement == "" {
		writeError(writer, http.StatusBadRequest, "invalid_request", "app_id and achievement are required")
		return
	}
	if input.DurationMS == 0 {
		input.DurationMS = 7000
	}
	if input.DurationMS < 1000 || input.DurationMS > 60000 {
		writeError(writer, http.StatusBadRequest, "invalid_duration", "duration_ms must be between 1000 and 60000")
		return
	}
	ctx := request.Context()
	if input.WaitForGameDir == nil {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 5*time.Minute)
		defer cancel()
	}
	var result map[string]any
	if err := a.callCore(ctx, "preview_achievement", input, &result); err != nil {
		writeCoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, result)
}

func (a *application) rollbackAchievementPreview(writer http.ResponseWriter, request *http.Request) {
	var input previewRequest
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	input.Achievement = strings.TrimSpace(input.Achievement)
	if input.AppID == 0 || input.Achievement == "" {
		writeError(writer, http.StatusBadRequest, "invalid_request", "app_id and achievement are required")
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 3*time.Minute)
	defer cancel()
	var result map[string]any
	if err := a.callCore(ctx, "rollback_achievement_preview", map[string]any{
		"app_id":      input.AppID,
		"achievement": input.Achievement,
	}, &result); err != nil {
		writeCoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, result)
}

func (a *application) syncAchievement(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		AppID       uint32  `json:"app_id"`
		Achievement string  `json:"achievement"`
		Provider    string  `json:"provider"`
		Timestamp   *uint32 `json:"timestamp,omitempty"`
		NativeToast bool    `json:"native_toast"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	input.Achievement = strings.TrimSpace(input.Achievement)
	input.Provider = strings.ToLower(strings.TrimSpace(input.Provider))
	if input.AppID == 0 || input.Achievement == "" || input.Provider == "" {
		writeError(writer, http.StatusBadRequest, "invalid_request", "app_id, achievement and provider are required")
		return
	}
	params := map[string]any{
		"app_id":       input.AppID,
		"achievement":  input.Achievement,
		"provider":     input.Provider,
		"native_toast": input.NativeToast,
	}
	if input.Timestamp != nil {
		params["timestamp"] = *input.Timestamp
	}
	ctx, cancel := context.WithTimeout(request.Context(), 3*time.Minute)
	defer cancel()
	if err := a.verifyProviderAchievement(ctx, input.AppID, input.Provider, input.Achievement); err != nil {
		writeError(writer, http.StatusUnprocessableEntity, "provider_state_unverified", err.Error())
		return
	}
	var result map[string]any
	if err := a.callCore(ctx, "store_steam_achievement", params, &result); err != nil {
		writeCoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, result)
}

func (a *application) verifyProviderAchievement(ctx context.Context, appID uint32, provider, achievement string) error {
	catalog, err := games.Discover(a.steamRoot)
	if err != nil {
		return err
	}
	var installed games.Installed
	for _, game := range catalog.Apps {
		if game.AppID == appID {
			installed = game
			break
		}
	}
	if installed.AppID == 0 {
		return fmt.Errorf("AppID %d is not installed", appID)
	}
	providerGame := providers.Game{AppID: appID, Name: installed.Name, InstallDir: installed.InstallDir, Provider: provider}
	if manifest, found := support.LoadAll(support.DefaultRoot())[appID]; found && strings.EqualFold(manifest.Provider, provider) {
		providerGame.ProviderProductID = manifest.ProviderProduct
		providerGame.SourceState = manifest.SourceState
	}
	watcher, err := providers.Open(providerGame, a.sampleNativeProvider)
	if err != nil {
		return err
	}
	defer watcher.Close()
	state, err := watcher.Snapshot(ctx)
	if err != nil {
		return err
	}
	if current, found := state[achievement]; found && current.Unlocked {
		return nil
	}
	suffix := achievementNumericSuffix(achievement)
	if suffix != "" {
		if current, found := state[suffix]; found && current.Unlocked {
			return nil
		}
	}
	return fmt.Errorf("achievement %s is not unlocked in %s", achievement, provider)
}

func achievementNumericSuffix(value string) string {
	start := len(value)
	for start > 0 && value[start-1] >= '0' && value[start-1] <= '9' {
		start--
	}
	if start == len(value) {
		return ""
	}
	trimmed := strings.TrimLeft(value[start:], "0")
	if trimmed == "" {
		return "0"
	}
	return trimmed
}

func (a *application) prepareGameSupport(writer http.ResponseWriter, request *http.Request) {
	appIDValue := strings.TrimSpace(request.PathValue("app_id"))
	appID64, err := strconv.ParseUint(appIDValue, 10, 32)
	if err != nil || appID64 == 0 {
		writeError(writer, http.StatusBadRequest, "invalid_app_id", "app_id must be a positive integer")
		return
	}
	catalog, err := games.Discover(a.steamRoot)
	if err != nil {
		writeError(writer, http.StatusServiceUnavailable, "steam_library_unavailable", err.Error())
		return
	}
	var installed games.Installed
	for _, candidate := range catalog.Apps {
		if candidate.AppID == uint32(appID64) {
			installed = candidate
			break
		}
	}
	if installed.AppID == 0 {
		writeError(writer, http.StatusNotFound, "game_not_installed", "Steam game is not installed")
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 45*time.Second)
	defer cancel()
	var achievementList achievementCatalog
	if err := a.callCore(ctx, "list_achievements", map[string]any{"app_id": installed.AppID}, &achievementList); err != nil {
		writeCoreError(writer, err)
		return
	}
	providerAchievements := make([]support.Achievement, 0, len(achievementList.Achievements))
	for _, item := range achievementList.Achievements {
		providerAchievements = append(providerAchievements, support.Achievement{
			APIName: item.APIName, Name: item.Name, Description: item.Description,
		})
	}
	prepared, err := support.PrepareUplayR2(
		support.DefaultRoot(), installed.AppID, installed.Name, installed.InstallDir, providerAchievements,
	)
	if err != nil {
		writeError(writer, http.StatusUnprocessableEntity, "provider_setup_failed", err.Error())
		return
	}
	status := "AGUARDA DADOS"
	if prepared.Manifest.Capabilities.SyncToSteam {
		status = "COMPLETO"
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"app_id":              installed.AppID,
		"game":                installed.Name,
		"provider":            prepared.Manifest.Provider,
		"provider_product_id": prepared.Manifest.ProviderProduct,
		"achievement_count":   prepared.Manifest.CatalogCount,
		"schema_path":         prepared.SchemaPath,
		"config_path":         prepared.ConfigPath,
		"manifest_path":       prepared.ManifestPath,
		"status":              status,
		"orchestrator":        "go",
	})
}

func (a *application) startMonitor(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		IntervalMS    uint32  `json:"interval_ms"`
		JournalPath   *string `json:"journal_path,omitempty"`
		Recover       *bool   `json:"recover,omitempty"`
		Notifications *bool   `json:"notifications,omitempty"`
		NativeToast   *bool   `json:"native_toast,omitempty"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil && !errors.Is(err, io.EOF) {
		writeError(writer, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if input.IntervalMS == 0 {
		input.IntervalMS = 500
	}
	if input.IntervalMS < 100 {
		writeError(writer, http.StatusBadRequest, "invalid_interval", "interval_ms must be at least 100")
		return
	}
	recoverEvents := true
	if input.Recover != nil {
		recoverEvents = *input.Recover
	}
	nativeToast := true
	if input.NativeToast != nil {
		nativeToast = *input.NativeToast
	}
	// A new UI monitoring session must not replay achievements from an older
	// session. Lines emitted between this reset and the SSE subscription remain
	// buffered, so startup events cannot be missed.
	a.supervisor.Events().ClearHistory()
	if a.eventSync != nil {
		a.eventSync.Start(nativeToast)
	}
	journalPath := ""
	if input.JournalPath != nil {
		journalPath = strings.TrimSpace(*input.JournalPath)
	}
	a.monitorMu.Lock()
	defer a.monitorMu.Unlock()
	if a.monitor != nil && a.monitor.Status().Running {
		writeJSON(writer, http.StatusOK, map[string]any{
			"monitoring":   true,
			"orchestrator": "go",
			"scope":        "active_game_sessions",
		})
		return
	}
	manager, err := monitoring.New(monitoring.Options{
		SteamRoot:     a.steamRoot,
		JournalPath:   journalPath,
		Interval:      time.Duration(input.IntervalMS) * time.Millisecond,
		SessionScan:   time.Second,
		FinalGrace:    3 * time.Second,
		Recover:       recoverEvents,
		Broker:        a.supervisor.Events(),
		NativeSampler: a.sampleNativeProvider,
		OnAchievement: func(event providers.Event) {
			var timestamp *uint32
			if event.Timestamp > 0 && event.Timestamp <= int64(^uint32(0)) {
				value := uint32(event.Timestamp)
				timestamp = &value
			}
			a.eventSync.Submit(achievementEvent{
				AppID: event.AppID, Provider: event.Provider,
				Achievement: event.Achievement, Timestamp: timestamp,
			})
		},
	})
	if err != nil {
		writeError(writer, http.StatusServiceUnavailable, "monitor_unavailable", err.Error())
		return
	}
	if err := manager.Start(); err != nil {
		writeError(writer, http.StatusServiceUnavailable, "monitor_start_failed", err.Error())
		return
	}
	a.monitor = manager
	writeJSON(writer, http.StatusOK, map[string]any{
		"monitoring":          true,
		"orchestrator":        "go",
		"scope":               "active_game_sessions",
		"final_poll_grace_ms": 3000,
	})
}

func providerNotificationsEnabled(requested *bool) bool {
	// Web mode owns the single branded Achievement Bridge tray icon. The Zig
	// provider balloons each register a generic tray icon, so they are opt-in.
	return requested != nil && *requested
}

func (a *application) stopMonitor(writer http.ResponseWriter, request *http.Request) {
	ctx, cancel := context.WithTimeout(request.Context(), 10*time.Second)
	defer cancel()
	a.monitorMu.Lock()
	manager := a.monitor
	a.monitor = nil
	a.monitorMu.Unlock()
	if manager != nil {
		if err := manager.Stop(ctx); err != nil {
			writeError(writer, http.StatusServiceUnavailable, "monitor_stop_failed", err.Error())
			return
		}
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"monitoring":   false,
		"orchestrator": "go",
	})
}

func (a *application) stopGoMonitor() {
	a.monitorMu.Lock()
	manager := a.monitor
	a.monitor = nil
	a.monitorMu.Unlock()
	if manager == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := manager.Stop(ctx); err != nil {
		log.Printf("stop Go monitor: %v", err)
	}
}

func (a *application) callCore(ctx context.Context, method string, params any, result any) error {
	err := a.core.Call(ctx, method, params, result)
	if err == nil {
		return nil
	}
	var remote *core.RemoteError
	if errors.As(err, &remote) {
		return err
	}

	a.recoveryMu.Lock()
	defer a.recoveryMu.Unlock()

	probeContext, cancelProbe := context.WithTimeout(ctx, 500*time.Millisecond)
	probeErr := a.core.Call(probeContext, "health", struct{}{}, nil)
	cancelProbe()
	if probeErr != nil {
		recoveryContext, cancelRecovery := context.WithTimeout(ctx, coreRecoveryTimeout)
		defer cancelRecovery()
		if ensureErr := a.supervisor.Ensure(recoveryContext); ensureErr != nil {
			return fmt.Errorf("recover Zig core after %v: %w", err, ensureErr)
		}
		log.Printf("Zig native core recovered")
	}
	return a.core.Call(ctx, method, params, result)
}

func (a *application) sampleNativeProvider(ctx context.Context, appID uint32) (providers.Snapshot, error) {
	var result struct {
		Active       bool     `json:"active"`
		Achievements []string `json:"achievements"`
	}
	if err := a.callCore(ctx, "sample_native_provider", map[string]any{
		"app_id":   appID,
		"provider": "rockstar",
	}, &result); err != nil {
		return nil, err
	}
	if !result.Active {
		return nil, providers.ErrStateUnavailable
	}
	state := make(providers.Snapshot, len(result.Achievements))
	for _, achievement := range result.Achievements {
		state[achievement] = providers.AchievementState{Unlocked: true}
	}
	return state, nil
}

func (a *application) monitorEvents(writer http.ResponseWriter, request *http.Request) {
	flusher, ok := writer.(http.Flusher)
	if !ok {
		writeError(writer, http.StatusInternalServerError, "stream_unsupported", "streaming is not supported")
		return
	}
	writer.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-cache")
	writer.Header().Set("Connection", "keep-alive")
	stream, history, unsubscribe := a.supervisor.Events().Subscribe()
	defer unsubscribe()
	writeEvent := func(line string) bool {
		data, err := json.Marshal(line)
		if err != nil {
			return false
		}
		if _, err := fmt.Fprintf(writer, "data: %s\n\n", data); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	for _, line := range history {
		if !writeEvent(line) {
			return
		}
	}
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-request.Context().Done():
			return
		case line, open := <-stream:
			if !open || !writeEvent(line) {
				return
			}
		case <-heartbeat.C:
			if _, err := fmt.Fprint(writer, ": heartbeat\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (a *application) shutdownAPI(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "shutting_down"})
	a.stopGoMonitor()
	if a.shutdown != nil {
		a.shutdown()
	}
}

func writeCoreError(writer http.ResponseWriter, err error) {
	var remote *core.RemoteError
	if errors.As(err, &remote) {
		status := http.StatusUnprocessableEntity
		if remote.Code == "AchievementNotFound" {
			status = http.StatusNotFound
		}
		writeError(writer, status, remote.Code, remote.Message)
		return
	}
	writeError(writer, http.StatusServiceUnavailable, "core_unavailable", err.Error())
}

func writeError(writer http.ResponseWriter, status int, code, message string) {
	writeJSON(writer, status, map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}

func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		started := time.Now()
		next.ServeHTTP(writer, request)
		log.Printf("%s %s duration=%s", request.Method, request.URL.Path, time.Since(started).Round(time.Millisecond))
	})
}

// webUIHandler serves a built single-page application from an explicitly
// configured directory. The gateway is loopback-only, but the root validation
// still prevents arbitrary paths from being served if a malformed URL arrives.
func webUIHandler(root string) (http.Handler, error) {
	if root == "" {
		return nil, nil
	}
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve Web UI directory: %w", err)
	}
	index := filepath.Join(absoluteRoot, "index.html")
	info, err := os.Stat(index)
	if err != nil {
		return nil, fmt.Errorf("read Web UI index: %w", err)
	}
	if info.IsDir() {
		return nil, fmt.Errorf("Web UI index is a directory: %s", index)
	}
	files := http.FileServer(http.Dir(absoluteRoot))
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet && request.Method != http.MethodHead {
			http.NotFound(writer, request)
			return
		}
		if strings.HasPrefix(request.URL.Path, "/v1/") {
			http.NotFound(writer, request)
			return
		}

		cleanPath := path.Clean("/" + request.URL.Path)
		relativePath := strings.TrimPrefix(cleanPath, "/")
		candidate := filepath.Join(absoluteRoot, filepath.FromSlash(relativePath))
		relativeCandidate, err := filepath.Rel(absoluteRoot, candidate)
		if err != nil || relativeCandidate == ".." || strings.HasPrefix(relativeCandidate, ".."+string(os.PathSeparator)) {
			http.NotFound(writer, request)
			return
		}
		if candidateInfo, statErr := os.Stat(candidate); statErr == nil && !candidateInfo.IsDir() {
			files.ServeHTTP(writer, request)
			return
		}

		// Frontend routes are resolved by Solid Router, so unknown browser paths
		// intentionally receive the SPA entrypoint instead of a server 404.
		http.ServeFile(writer, request, index)
	}), nil
}

func requireLoopback(address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("invalid listen address %q: %w", address, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("Achievement Bridge only accepts loopback addresses, got %q", address)
	}
	return nil
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func findCoreExecutable() (string, error) {
	executable, err := os.Executable()
	if err == nil {
		candidate := filepath.Join(filepath.Dir(executable), "achievement-bridge.exe")
		if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	for _, candidate := range []string{
		filepath.Join("zig-out", "bin", "achievement-bridge.exe"),
		"achievement-bridge.exe",
	} {
		absolute, absoluteErr := filepath.Abs(candidate)
		if absoluteErr != nil {
			continue
		}
		if info, statErr := os.Stat(absolute); statErr == nil && !info.IsDir() {
			return absolute, nil
		}
	}
	return "", fmt.Errorf("achievement-bridge.exe was not found")
}
