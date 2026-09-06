package main

import (
	"context"
	"log"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/core"
	"github.com/YlanzinhoY/AchievementBridge/api/internal/events"
)

type achievementEvent struct {
	AppID       uint32
	Provider    string
	Achievement string
	Timestamp   *uint32
}

type achievementEventParser struct {
	inside bool
	fields map[string]string
}

func (p *achievementEventParser) Push(line string) *achievementEvent {
	trimmed := strings.TrimSpace(line)
	if trimmed == "[AchievementBridge]" {
		p.inside = true
		p.fields = make(map[string]string)
		return nil
	}
	if !p.inside {
		return nil
	}
	if trimmed != "" {
		if key, value, ok := strings.Cut(trimmed, "="); ok {
			p.fields[key] = value
		}
		return nil
	}
	p.inside = false
	if p.fields["state"] != "unlocked" || !syncProvider(p.fields["provider"]) {
		return nil
	}
	appID, err := strconv.ParseUint(p.fields["appid"], 10, 32)
	if err != nil || appID == 0 || p.fields["achievement"] == "" {
		return nil
	}
	event := &achievementEvent{
		AppID:       uint32(appID),
		Provider:    p.fields["provider"],
		Achievement: p.fields["achievement"],
	}
	if value, err := strconv.ParseUint(p.fields["timestamp"], 10, 32); err == nil && value > 0 {
		timestamp := uint32(value)
		event.Timestamp = &timestamp
	}
	return event
}

func syncProvider(provider string) bool {
	switch strings.ToLower(provider) {
	case "gse", "rune", "rockstar", "uplay_r2":
		return true
	default:
		return false
	}
}

type eventSyncer struct {
	client      *core.Client
	broker      *events.Broker
	once        sync.Once
	nativeToast atomic.Bool
}

func newEventSyncer(client *core.Client, broker *events.Broker) *eventSyncer {
	return &eventSyncer{client: client, broker: broker}
}

func (s *eventSyncer) Start(nativeToast bool) {
	s.nativeToast.Store(nativeToast)
	s.once.Do(func() { go s.run() })
}

func (s *eventSyncer) run() {
	stream, history, unsubscribe := s.broker.Subscribe()
	defer unsubscribe()
	parser := &achievementEventParser{}
	consume := func(line string) {
		event := parser.Push(line)
		if event == nil {
			return
		}
		params := map[string]any{
			"app_id":       event.AppID,
			"achievement":  event.Achievement,
			"provider":     event.Provider,
			"native_toast": s.nativeToast.Load(),
		}
		if event.Timestamp != nil {
			params["timestamp"] = *event.Timestamp
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		var result map[string]any
		if err := s.client.Call(ctx, "sync_achievement", params, &result); err != nil {
			log.Printf("automatic Steam sync failed appid=%d achievement=%s provider=%s: %v", event.AppID, event.Achievement, event.Provider, err)
			return
		}
		log.Printf("automatic Steam sync complete appid=%d achievement=%s provider=%s route=%v", event.AppID, event.Achievement, event.Provider, result["route"])
	}
	for _, line := range history {
		consume(line)
	}
	for line := range stream {
		consume(line)
	}
}
