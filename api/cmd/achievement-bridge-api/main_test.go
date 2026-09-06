package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequireLoopback(t *testing.T) {
	for _, address := range []string{"127.0.0.1:47650", "[::1]:47650"} {
		if err := requireLoopback(address); err != nil {
			t.Fatalf("expected %s to be accepted: %v", address, err)
		}
	}
	for _, address := range []string{"0.0.0.0:47650", "192.168.1.10:47650", "invalid"} {
		if err := requireLoopback(address); err == nil {
			t.Fatalf("expected %s to be rejected", address)
		}
	}
}

func TestPreviewRejectsMissingIdentity(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/v1/achievement-previews", strings.NewReader(`{"app_id":0}`))
	recorder := httptest.NewRecorder()
	(&application{}).previewAchievement(recorder, request)
	if recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "invalid_request") {
		t.Fatalf("unexpected response: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestMonitorRejectsUnsafePollingInterval(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/v1/monitor/start", strings.NewReader(`{"interval_ms":50}`))
	recorder := httptest.NewRecorder()
	(&application{}).startMonitor(recorder, request)
	if recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "invalid_interval") {
		t.Fatalf("unexpected response: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestSyncRejectsMissingProvider(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/v1/achievement-syncs", strings.NewReader(`{"app_id":3046600,"achievement":"ACHIEVEMENT_02"}`))
	recorder := httptest.NewRecorder()
	(&application{}).syncAchievement(recorder, request)
	if recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "invalid_request") {
		t.Fatalf("unexpected response: %d %s", recorder.Code, recorder.Body.String())
	}
}
