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

func TestAchievementEventParserRoutesCanonicalEvents(t *testing.T) {
	parser := &achievementEventParser{}
	lines := []string{
		"[AchievementBridge]",
		"provider=uplay_r2",
		"appid=2842040",
		"product_id=64181",
		"achievement=19",
		"timestamp=1234",
		"state=unlocked",
		"",
	}
	var event *achievementEvent
	for _, line := range lines {
		if parsed := parser.Push(line); parsed != nil {
			event = parsed
		}
	}
	if event == nil {
		t.Fatal("expected an achievement event")
	}
	if event.AppID != 2842040 || event.Provider != "uplay_r2" || event.Achievement != "19" {
		t.Fatalf("unexpected event: %+v", event)
	}
	if event.Timestamp == nil || *event.Timestamp != 1234 {
		t.Fatalf("unexpected timestamp: %+v", event.Timestamp)
	}
}

func TestAchievementEventParserRejectsProviderOnlyIdentity(t *testing.T) {
	parser := &achievementEventParser{}
	for _, line := range []string{
		"[AchievementBridge]",
		"provider=uplay_r2",
		"product_id=64181",
		"achievement=19",
		"state=unlocked",
		"",
	} {
		if event := parser.Push(line); event != nil {
			t.Fatalf("unexpected event without canonical Steam AppID: %+v", event)
		}
	}
}
