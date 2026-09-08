package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/googledrive"
)

type fakeGoogleDriveClient struct {
	file     *googledrive.File
	uploaded []byte
}

func (f *fakeGoogleDriveClient) FindAppDataFile(context.Context, string) (*googledrive.File, error) {
	return f.file, nil
}

func (f *fakeGoogleDriveClient) UploadAppData(_ context.Context, _ string, content []byte) (googledrive.File, error) {
	f.uploaded = append([]byte(nil), content...)
	return googledrive.File{ID: "remote-journal", Name: googleDriveJournalName}, nil
}

func TestGoogleDriveStatusIsSafeWhenNotConfigured(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/v1/cloud/google-drive/status", nil)
	(&application{googleDrive: &googleDriveBackup{}}).googleDriveStatus(recorder, request)
	if recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), `"configured":false`) {
		t.Fatalf("unexpected response: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestBackupToGoogleDriveUploadsJournal(t *testing.T) {
	directory := t.TempDir()
	journal := filepath.Join(directory, "journal.jsonl")
	content := []byte("{\"kind\":\"event\"}\n")
	if err := os.WriteFile(journal, content, 0o600); err != nil {
		t.Fatal(err)
	}
	client := &fakeGoogleDriveClient{}
	app := &application{googleDrive: &googleDriveBackup{
		client:      client,
		journalPath: journal,
		configured:  true,
	}}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/cloud/google-drive/backup", nil)
	app.backupToGoogleDrive(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("unexpected response: %d %s", recorder.Code, recorder.Body.String())
	}
	if string(client.uploaded) != string(content) {
		t.Fatalf("unexpected uploaded journal: %q", client.uploaded)
	}
}
