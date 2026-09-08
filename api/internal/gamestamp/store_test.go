package gamestamp

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRecordCreatesAndUpdatesVerifiedGameStamp(t *testing.T) {
	store := New(t.TempDir())
	store.now = func() time.Time { return time.Unix(300, 0) }
	if err := store.Record(Event{
		AppID: 3240220, Provider: "Rockstar", SourceID: "AWARD_SHARKS", UnlockedAt: 200, SteamStatus: "detected",
	}); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Unix(310, 0) }
	if err := store.Record(Event{
		AppID: 3240220, Provider: "rockstar", SourceID: "AWARD_SHARKS", CanonicalAPIName: "AWARD_SHARKS", UnlockedAt: 200, SteamStatus: "synced", SteamRoute: "local-cache",
	}); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Unix(400, 0) }
	if err := store.Record(Event{
		AppID: 3240220, Provider: "rockstar", SourceID: "AWARD_STOCKS", CanonicalAPIName: "AWARD_STOCKS", UnlockedAt: 350, SteamStatus: "synced", SteamRoute: "abi",
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

func TestImportJournalBackfillsExistingAchievementsWithoutDowngrade(t *testing.T) {
	root := t.TempDir()
	store := New(filepath.Join(root, "games"))
	store.now = func() time.Time { return time.Unix(200, 0) }
	if err := store.Record(Event{
		AppID: 3046600, Provider: "rune", SourceID: "ACHIEVEMENT_002", CanonicalAPIName: "ACHIEVEMENT_002", UnlockedAt: 100, SteamStatus: "synced", SteamRoute: "abi",
	}); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(root, "journal.jsonl")
	content := "{\"kind\":\"baseline\",\"app_id\":1,\"source_id\":\"IGNORE\"}\n" +
		"{\"kind\":\"event\",\"app_id\":3046600,\"provider\":\"rune\",\"source_id\":\"ACHIEVEMENT_002\",\"unlocked_at\":100}\n" +
		"{\"kind\":\"event\",\"app_id\":3046600,\"provider\":\"rune\",\"source_id\":\"ACHIEVEMENT_047\",\"unlocked_at\":150}\n"
	if err := os.WriteFile(journal, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Unix(300, 0) }
	imported, err := store.ImportJournal(journal, filepath.Join(root, "support"))
	if err != nil {
		t.Fatal(err)
	}
	if imported != 2 {
		t.Fatalf("unexpected imported count: %d", imported)
	}
	stamp, err := load(store.Path(3046600))
	if err != nil {
		t.Fatal(err)
	}
	if len(stamp.Achievements) != 2 {
		t.Fatalf("unexpected achievements: %+v", stamp.Achievements)
	}
	if stamp.Achievements[0].SteamStatus != "synced" || stamp.Achievements[0].SteamRoute != "abi" {
		t.Fatalf("historical import downgraded synchronized state: %+v", stamp.Achievements[0])
	}
}

func TestRecordRefusesTamperedStamp(t *testing.T) {
	store := New(t.TempDir())
	store.now = func() time.Time { return time.Unix(100, 0) }
	if err := store.Record(Event{AppID: 42, Provider: "gse", SourceID: "ACH_ONE", UnlockedAt: 90}); err != nil {
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
	stamp.Achievements[0].SourceID = "ACH_TAMPERED"
	content, err = json.Marshal(stamp)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.Path(42), content, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.Record(Event{AppID: 42, Provider: "gse", SourceID: "ACH_TWO", UnlockedAt: 95}); err == nil {
		t.Fatal("tampered stamp was accepted")
	}
}

func TestImportJournalNormalizesUplayProductIDs(t *testing.T) {
	root := t.TempDir()
	supportRoot := filepath.Join(root, "support")
	manifestDir := filepath.Join(supportRoot, "games", "3751950")
	if err := os.MkdirAll(manifestDir, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := `{"schema_version":1,"steam_app_id":3751950,"provider":"uplay_r2","provider_product_id":66088}`
	if err := os.WriteFile(filepath.Join(manifestDir, "support.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(root, "journal.jsonl")
	content := `{"kind":"event","app_id":66088,"provider":"uplay_r2","source_id":"14","unlocked_at":100}` + "\n" +
		`{"kind":"event","app_id":64181,"provider":"uplay_r2","source_id":"19","unlocked_at":150}` + "\n"
	if err := os.WriteFile(journal, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	store := New(filepath.Join(root, "games"))
	count, err := store.ImportJournal(journal, supportRoot)
	if err != nil || count != 1 {
		t.Fatalf("import: count=%d err=%v", count, err)
	}
	stamp, err := Load(store.Path(3751950))
	if err != nil {
		t.Fatal(err)
	}
	if stamp.AppID != 3751950 || stamp.Achievements[0].SourceID != "14" || stamp.Achievements[0].APIName != "" {
		t.Fatalf("unexpected normalized identity: %+v", stamp)
	}
	for _, id := range []uint32{66088, 64181} {
		if _, err := os.Stat(store.Path(id)); !os.IsNotExist(err) {
			t.Fatalf("created a stamp using provider id %d", id)
		}
	}

	// Two manifests claiming the same product must not guess the owner.
	otherDir := filepath.Join(supportRoot, "games", "42")
	if err := os.MkdirAll(otherDir, 0o700); err != nil {
		t.Fatal(err)
	}
	other := `{"schema_version":1,"steam_app_id":42,"provider":"uplay_r2","provider_product_id":66088}`
	if err := os.WriteFile(filepath.Join(otherDir, "support.json"), []byte(other), 0o600); err != nil {
		t.Fatal(err)
	}
	ambiguous := New(filepath.Join(root, "ambiguous-games"))
	if count, err := ambiguous.ImportJournal(journal, supportRoot); err != nil || count != 0 {
		t.Fatalf("ambiguous mapping accepted: count=%d err=%v", count, err)
	}
}

func TestRecordIsIdempotentAndKeepsEarliestKnownTime(t *testing.T) {
	store := New(t.TempDir())
	store.now = func() time.Time { return time.Unix(200, 0) }
	event := Event{AppID: 42, Provider: "gse", SourceID: "ACH_ONE"}
	if err := store.Record(event); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(store.Path(42))
	if err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return time.Unix(300, 0) }
	if err := store.Record(event); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(store.Path(42))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("repeated unknown timestamp rewrote the stamp")
	}
	event.UnlockedAt = 100
	event.SteamStatus = "synced"
	event.CanonicalAPIName = "STEAM_ONE"
	if err := store.Record(event); err != nil {
		t.Fatal(err)
	}
	event.UnlockedAt = 150
	event.SteamStatus = "detected"
	if err := store.Record(event); err != nil {
		t.Fatal(err)
	}
	stamp, err := Load(store.Path(42))
	if err != nil {
		t.Fatal(err)
	}
	if stamp.FirstAchievementAt != 100 || stamp.LastAchievementAt != 100 || stamp.Achievements[0].SteamStatus != "synced" || stamp.Achievements[0].APIName != "STEAM_ONE" {
		t.Fatalf("duplicate observation changed confirmed state: %+v", stamp)
	}
	// The same provider ID from a different provider is independent.
	event.Provider = "rune"
	if err := store.Record(event); err != nil {
		t.Fatal(err)
	}
	stamp, err = Load(store.Path(42))
	if err != nil || len(stamp.Achievements) != 2 {
		t.Fatalf("provider identity collision: %+v %v", stamp, err)
	}
}
