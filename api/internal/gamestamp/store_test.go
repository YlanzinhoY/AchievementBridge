package gamestamp

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestRecordCreatesAndUpdatesVerifiedGameStamp(t *testing.T) {
	store := New(t.TempDir())
	store.now = func() time.Time { return time.Unix(300, 0) }
	if err := store.Record(Event{
		AppID: 3240220, Provider: "Rockstar", APIName: "AWARD_SHARKS", UnlockedAt: 200, SteamStatus: "detected",
	}); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Unix(310, 0) }
	if err := store.Record(Event{
		AppID: 3240220, Provider: "rockstar", APIName: "AWARD_SHARKS", UnlockedAt: 200, SteamStatus: "synced", SteamRoute: "local-cache",
	}); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Unix(400, 0) }
	if err := store.Record(Event{
		AppID: 3240220, Provider: "rockstar", APIName: "AWARD_STOCKS", UnlockedAt: 350, SteamStatus: "synced", SteamRoute: "abi",
	}); err != nil {
		t.Fatal(err)
	}

	stamp, err := load(store.Path(3240220))
	if err != nil {
		t.Fatal(err)
	}
	if stamp.Kind != Kind || stamp.SchemaVersion != 1 || stamp.Provider != "rockstar" {
		t.Fatalf("unexpected marker: %+v", stamp)
	}
	if stamp.FirstAchievementAt != 200 || stamp.LastAchievementAt != 350 || len(stamp.Achievements) != 2 {
		t.Fatalf("unexpected achievement history: %+v", stamp)
	}
	if stamp.Achievements[0].SteamStatus != "synced" || stamp.Achievements[0].SteamRoute != "local-cache" {
		t.Fatalf("unexpected synchronized achievement: %+v", stamp.Achievements[0])
	}
}

func TestRecordRefusesTamperedStamp(t *testing.T) {
	store := New(t.TempDir())
	store.now = func() time.Time { return time.Unix(100, 0) }
	if err := store.Record(Event{AppID: 42, Provider: "gse", APIName: "ACH_ONE", UnlockedAt: 90}); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(store.Path(42))
	if err != nil {
		t.Fatal(err)
	}
	var stamp Stamp
	if err := json.Unmarshal(content, &stamp); err != nil {
		t.Fatal(err)
	}
	stamp.Achievements[0].APIName = "ACH_TAMPERED"
	content, err = json.Marshal(stamp)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.Path(42), content, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.Record(Event{AppID: 42, Provider: "gse", APIName: "ACH_TWO", UnlockedAt: 95}); err == nil {
		t.Fatal("tampered stamp was accepted")
	}
}
