package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/googledrive"
)

const googleDriveJournalName = "achievement-bridge-journal.jsonl"

type googleDriveClient interface {
	FindAppDataFile(context.Context, string) (*googledrive.File, error)
	UploadAppData(context.Context, string, []byte) (googledrive.File, error)
}

type googleDriveBackup struct {
	client      googleDriveClient
	journalPath string
	configured  bool
}

func newGoogleDriveBackup() *googleDriveBackup {
	token := strings.TrimSpace(os.Getenv("ACHIEVEMENT_BRIDGE_GOOGLE_DRIVE_TOKEN"))
	return &googleDriveBackup{
		client:      googledrive.New(&http.Client{Timeout: 30 * time.Second}, token),
		journalPath: defaultJournalPath(),
		configured:  token != "",
	}
}

func defaultJournalPath() string {
	if configured := strings.TrimSpace(os.Getenv("ACHIEVEMENT_BRIDGE_JOURNAL_PATH")); configured != "" {
		return configured
	}
	root, err := os.UserCacheDir()
	if err != nil || root == "" {
		return filepath.Join(".achievement-bridge", "journal.jsonl")
	}
	return filepath.Join(root, "AchievementBridge", "journal.jsonl")
}

func (a *application) googleDriveStatus(writer http.ResponseWriter, request *http.Request) {
	if a.googleDrive == nil || !a.googleDrive.configured {
		writeJSON(writer, http.StatusOK, map[string]any{
			"configured": false,
			"connected":  false,
		})
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 15*time.Second)
	defer cancel()
	file, err := a.googleDrive.client.FindAppDataFile(ctx, googleDriveJournalName)
	if err != nil {
		writeError(writer, http.StatusBadGateway, "google_drive_unavailable", err.Error())
		return
	}
	response := map[string]any{
		"configured":     true,
		"connected":      true,
		"remote_present": file != nil,
	}
	if file != nil {
		response["file"] = file
	}
	writeJSON(writer, http.StatusOK, response)
}

func (a *application) backupToGoogleDrive(writer http.ResponseWriter, request *http.Request) {
	if a.googleDrive == nil || !a.googleDrive.configured {
		writeError(writer, http.StatusPreconditionFailed, "google_drive_not_configured", "Google Drive is not connected")
		return
	}
	content, err := readJournal(a.googleDrive.journalPath)
	if err != nil {
		writeError(writer, http.StatusUnprocessableEntity, "journal_unavailable", err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 30*time.Second)
	defer cancel()
	file, err := a.googleDrive.client.UploadAppData(ctx, googleDriveJournalName, content)
	if err != nil {
		writeError(writer, http.StatusBadGateway, "google_drive_upload_failed", err.Error())
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"backed_up": true,
		"bytes":     len(content),
		"file":      file,
	})
}

func readJournal(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open achievement journal: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect achievement journal: %w", err)
	}
	const maximumJournalSize = 32 * 1024 * 1024
	if info.Size() > maximumJournalSize {
		return nil, fmt.Errorf("achievement journal exceeds %d bytes", maximumJournalSize)
	}
	content, err := io.ReadAll(io.LimitReader(file, maximumJournalSize+1))
	if err != nil {
		return nil, fmt.Errorf("read achievement journal: %w", err)
	}
	return content, nil
}
