package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/core"
)

const (
	defaultAPIAddress  = "127.0.0.1:47650"
	defaultCoreAddress = "127.0.0.1:47651"
)

type application struct {
	core       *core.Client
	supervisor *core.Supervisor
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
	AppID            uint32  `json:"app_id"`
	Name             string  `json:"name"`
	Directory        string  `json:"directory"`
	Provider         string  `json:"provider"`
	Confidence       uint8   `json:"confidence"`
	AchievementCount *uint64 `json:"achievement_count"`
	Status           string  `json:"status"`
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
	startupContext, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	if err := supervisor.Ensure(startupContext); err != nil {
		cancel()
		log.Fatal(err)
	}
	cancel()
	defer supervisor.Close()

	app := &application{core: coreClient, supervisor: supervisor}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", app.health)
	mux.HandleFunc("GET /v1/games", app.listGames)
	mux.HandleFunc("GET /v1/games/{app_id}/achievements", app.listAchievements)
	mux.HandleFunc("POST /v1/achievement-previews", app.previewAchievement)
	mux.HandleFunc("POST /v1/achievement-previews/rollback", app.rollbackAchievementPreview)

	server := &http.Server{
		Addr:              *apiAddress,
		Handler:           requestLogger(mux),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	shutdownContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdownContext.Done()
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
	ctx, cancel := context.WithTimeout(request.Context(), 3*time.Minute)
	defer cancel()
	var result struct {
		Games []gameSupport `json:"games"`
	}
	if err := a.core.Call(ctx, "inspect_games", map[string]any{"verify_schema": verifySchema}, &result); err != nil {
		writeCoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, result)
}

func (a *application) health(writer http.ResponseWriter, request *http.Request) {
	ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
	defer cancel()
	var coreHealth map[string]any
	if err := a.core.Call(ctx, "health", struct{}{}, &coreHealth); err != nil {
		writeError(writer, http.StatusServiceUnavailable, "core_unavailable", err.Error())
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"service": "achievement-bridge-api",
		"status":  "ready",
		"core":    coreHealth,
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
	if err := a.core.Call(ctx, "list_achievements", map[string]any{"app_id": appID}, &catalog); err != nil {
		writeCoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, catalog)
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
	if err := a.core.Call(ctx, "preview_achievement", input, &result); err != nil {
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
	if err := a.core.Call(ctx, "rollback_achievement_preview", map[string]any{
		"app_id":      input.AppID,
		"achievement": input.Achievement,
	}, &result); err != nil {
		writeCoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, result)
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
