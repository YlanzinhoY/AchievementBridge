package providers

import "testing"

func TestGSEAndRUNEProduceTheSameSnapshotContract(t *testing.T) {
	gse, err := parseGSE("achievements.json", []byte(`{
		"ACH_OLD":{"earned":true,"earned_time":100},
		"ACH_NEW":{"earned":false,"earned_time":0}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	rune, err := parseRUNE("achievements.ini", []byte("[ACH_OLD]\nAchieved=1\nUnlockTime=100\n[ACH_NEW]\nAchieved=0\n"))
	if err != nil {
		t.Fatal(err)
	}
	if gse["ACH_OLD"] != rune["ACH_OLD"] || gse["ACH_NEW"] != rune["ACH_NEW"] {
		t.Fatalf("provider contracts differ: gse=%+v rune=%+v", gse, rune)
	}
}

func TestDiffEmitsOnlyLockedToUnlockedTransitions(t *testing.T) {
	before := Snapshot{"OLD": {Unlocked: true}, "NEW": {Unlocked: false}}
	after := Snapshot{"OLD": {Unlocked: true}, "NEW": {Unlocked: true, Timestamp: 123}}
	events := Diff(before, after)
	if len(events) != 1 || events[0].Achievement != "NEW" || events[0].Timestamp != 123 {
		t.Fatalf("unexpected events: %+v", events)
	}
}

func TestUbisoftSpoolNormalizesMilliseconds(t *testing.T) {
	appendVarint := func(destination []byte, value uint64) []byte {
		for value >= 0x80 {
			destination = append(destination, byte(value)|0x80)
			value >>= 7
		}
		return append(destination, byte(value))
	}
	payload := appendVarint(nil, 8)
	payload = appendVarint(payload, 27)
	payload = appendVarint(payload, 16)
	payload = appendVarint(payload, 1_700_000_000_000)
	data := appendVarint(nil, 10)
	data = appendVarint(data, uint64(len(payload)))
	data = append(data, payload...)
	state, err := parseUbisoftSpool(data)
	if err != nil {
		t.Fatal(err)
	}
	if value := state["27"]; !value.Unlocked || value.Timestamp != 1_700_000_000 {
		t.Fatalf("unexpected Ubisoft state: %+v", value)
	}
}
