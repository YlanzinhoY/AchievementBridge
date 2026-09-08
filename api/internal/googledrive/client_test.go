package googledrive

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestUploadAppDataCreatesPrivateFile(t *testing.T) {
	var uploadSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer secret-token" {
			t.Fatalf("unexpected authorization header: %q", request.Header.Get("Authorization"))
		}
		switch request.URL.Path {
		case "/drive/v3/files":
			_, _ = writer.Write([]byte(`{"files":[]}`))
		case "/upload/drive/v3/files":
			uploadSeen = true
			if request.URL.Query().Get("uploadType") != "multipart" {
				t.Fatalf("unexpected upload type: %q", request.URL.Query().Get("uploadType"))
			}
			body, err := io.ReadAll(request.Body)
			if err != nil {
				t.Fatal(err)
			}
			payload := string(body)
			if !strings.Contains(payload, `"parents":["appDataFolder"]`) || !strings.Contains(payload, "event-data") {
				t.Fatalf("multipart upload does not contain private metadata and journal: %s", payload)
			}
			writer.Header().Set("Content-Type", "application/json")
			_, _ = writer.Write([]byte(`{"id":"drive-file","name":"achievement-bridge-journal.jsonl","size":"10"}`))
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	client := New(server.Client(), "secret-token")
	client.apiBaseURL = server.URL + "/drive/v3"
	client.uploadBaseURL = server.URL + "/upload/drive/v3"
	file, err := client.UploadAppData(context.Background(), "achievement-bridge-journal.jsonl", []byte("event-data"))
	if err != nil {
		t.Fatal(err)
	}
	if !uploadSeen || file.ID != "drive-file" {
		t.Fatalf("unexpected upload result: seen=%v file=%+v", uploadSeen, file)
	}
}

func TestUploadAppDataUpdatesExistingFile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/drive/v3/files":
			_, _ = writer.Write([]byte(`{"files":[{"id":"existing-file","name":"achievement-bridge-journal.jsonl"}]}`))
		case "/upload/drive/v3/files/existing-file":
			if request.Method != http.MethodPatch || request.URL.Query().Get("uploadType") != "media" {
				t.Fatalf("unexpected update request: %s %s", request.Method, request.URL.String())
			}
			_, _ = writer.Write([]byte(`{"id":"existing-file","name":"achievement-bridge-journal.jsonl","size":"7"}`))
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	client := New(server.Client(), "secret-token")
	client.apiBaseURL = server.URL + "/drive/v3"
	client.uploadBaseURL = server.URL + "/upload/drive/v3"
	file, err := client.UploadAppData(context.Background(), "achievement-bridge-journal.jsonl", []byte("updated"))
	if err != nil {
		t.Fatal(err)
	}
	if file.ID != "existing-file" || file.Size != "7" {
		t.Fatalf("unexpected file: %+v", file)
	}
}
