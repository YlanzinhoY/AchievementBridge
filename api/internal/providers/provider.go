package providers

import (
	"context"
	"errors"
	"time"
)

// ErrStateUnavailable means the provider has not created its achievement
// state yet. This is expected before a game's first unlock.
var ErrStateUnavailable = errors.New("provider state is not available")

type AchievementState struct {
	Unlocked  bool
	Timestamp int64
}

type Snapshot map[string]AchievementState

type Game struct {
	AppID             uint32
	Name              string
	InstallDir        string
	Provider          string
	ProviderProductID uint32
	SourceState       string
}

type Event struct {
	AppID       uint32
	Provider    string
	Achievement string
	Timestamp   int64
	DetectedAt  time.Time
	Recovered   bool
}

// Watcher is intentionally pull-based. The Go session coordinator decides
// when a provider may read state and therefore no watcher can outlive its game.
type Watcher interface {
	Provider() string
	Snapshot(context.Context) (Snapshot, error)
	Close() error
}

type Factory interface {
	Provider() string
	Open(Game) (Watcher, error)
}

func Open(game Game, nativeSampler NativeSampler) (Watcher, error) {
	var factory Factory
	switch game.Provider {
	case "gse":
		factory = GSEFactory{}
	case "rune":
		factory = RUNEFactory{}
	case "rockstar":
		factory = RockstarFactory{NativeSample: nativeSampler}
	case "ubisoft":
		factory = UbisoftFactory{}
	case "uplay_r2":
		factory = UplayR2Factory{}
	default:
		return nil, errors.New("unsupported achievement provider")
	}
	return factory.Open(game)
}

func Diff(before, after Snapshot) []Event {
	result := make([]Event, 0)
	for id, current := range after {
		if !current.Unlocked || before[id].Unlocked {
			continue
		}
		result = append(result, Event{Achievement: id, Timestamp: current.Timestamp})
	}
	return result
}
