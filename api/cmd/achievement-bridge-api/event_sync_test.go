package main

import (
	"context"
	"errors"
	"testing"

	"github.com/YlanzinhoY/AchievementBridge/api/internal/gamestamp"
)

type recordingStampWriter struct {
	events []gamestamp.Event
}

func (writer *recordingStampWriter) Record(event gamestamp.Event) error {
	writer.events = append(writer.events, event)
	return nil
}

func TestEventSyncerStampsDetectedAndSyncedAchievement(t *testing.T) {
	stamps := &recordingStampWriter{}
	syncer := &eventSyncer{
		stamps: stamps,
		call: func(_ context.Context, method string, _ any, result any) error {
			if method != "project_local_achievement" {
				t.Fatalf("unexpected core method: %s", method)
			}
			output := result.(*map[string]any)
			*output = map[string]any{"route": "steam_local_projection", "achievement": "AWARD_SHARKS_CANONICAL"}
			return nil
		},
	}
	timestamp := uint32(123)
	syncer.syncEvent(&achievementEvent{AppID: 3240220, Provider: "rockstar", Achievement: "AWARD_SHARKS", Timestamp: &timestamp})
	if len(stamps.events) != 2 {
		t.Fatalf("expected two stamp updates, got %d", len(stamps.events))
	}
	if stamps.events[0].SteamStatus != "detected" || stamps.events[1].SteamStatus != "synced" {
		t.Fatalf("unexpected stamp transition: %+v", stamps.events)
	}
	if stamps.events[1].SteamRoute != "steam_local_projection" || stamps.events[1].UnlockedAt != 123 {
		t.Fatalf("unexpected synchronized stamp: %+v", stamps.events[1])
	}
	if stamps.events[1].SourceID != "AWARD_SHARKS" || stamps.events[1].CanonicalAPIName != "AWARD_SHARKS_CANONICAL" {
		t.Fatalf("unexpected achievement identity: %+v", stamps.events[1])
	}
}

func TestEventSyncerPreservesAchievementWhenSteamSyncFails(t *testing.T) {
	stamps := &recordingStampWriter{}
	syncer := &eventSyncer{
		stamps: stamps,
		call: func(context.Context, string, any, any) error {
			return errors.New("local projection unavailable")
		},
	}
	syncer.syncEvent(&achievementEvent{AppID: 3046600, Provider: "rune", Achievement: "ACHIEVEMENT_002"})
	if len(stamps.events) != 2 || stamps.events[0].SteamStatus != "detected" || stamps.events[1].SteamStatus != "failed" {
		t.Fatalf("unexpected failed stamp transition: %+v", stamps.events)
	}
}
