package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebUIHandlerServesAssetsAndSPAEntryPoint(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "index.html"), []byte("<main>bridge</main>"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "assets"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "assets", "app.js"), []byte("console.log('bridge')"), 0o600); err != nil {
		t.Fatal(err)
	}

	handler, err := webUIHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	if handler == nil {
		t.Fatal("expected a Web UI handler")
	}

	assetRequest := httptest.NewRequest(http.MethodGet, "/assets/app.js", nil)
	assetRecorder := httptest.NewRecorder()
	handler.ServeHTTP(assetRecorder, assetRequest)
	if assetRecorder.Code != http.StatusOK || !strings.Contains(assetRecorder.Body.String(), "console.log") {
		t.Fatalf("unexpected asset response: %d %q", assetRecorder.Code, assetRecorder.Body.String())
	}

	routeRequest := httptest.NewRequest(http.MethodGet, "/games", nil)
	routeRecorder := httptest.NewRecorder()
	handler.ServeHTTP(routeRecorder, routeRequest)
	if routeRecorder.Code != http.StatusOK || !strings.Contains(routeRecorder.Body.String(), "<main>bridge</main>") {
		t.Fatalf("unexpected SPA response: %d %q", routeRecorder.Code, routeRecorder.Body.String())
	}

	apiRequest := httptest.NewRequest(http.MethodGet, "/v1/unknown", nil)
	apiRecorder := httptest.NewRecorder()
	handler.ServeHTTP(apiRecorder, apiRequest)
	if apiRecorder.Code != http.StatusNotFound {
		t.Fatalf("expected API-like path to stay unavailable, got %d", apiRecorder.Code)
	}
}
