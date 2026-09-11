package providers

import (
	"context"
	"encoding/binary"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type UbisoftFactory struct {
	LocalAppData string
}

func (UbisoftFactory) Provider() string { return "ubisoft" }

func (f UbisoftFactory) Open(game Game) (Watcher, error) {
	root := f.LocalAppData
	if root == "" {
		root = os.Getenv("LOCALAPPDATA")
	}
	if root == "" {
		return nil, fmt.Errorf("LOCALAPPDATA is unavailable")
	}
	productID := game.ProviderProductID
	if productID == 0 {
		return nil, fmt.Errorf("Ubisoft product id is unknown for AppID %d", game.AppID)
	}
	return &ubisoftWatcher{
		root:      filepath.Join(root, "Ubisoft Game Launcher", "spool"),
		productID: productID,
	}, nil
}

type ubisoftWatcher struct {
	root      string
	productID uint32
}

func (*ubisoftWatcher) Provider() string { return "ubisoft" }
func (*ubisoftWatcher) Close() error     { return nil }

func (w *ubisoftWatcher) Snapshot(ctx context.Context) (Snapshot, error) {
	wanted := strconv.FormatUint(uint64(w.productID), 10) + ".spool"
	var selected string
	var selectedMtime int64
	err := filepath.WalkDir(w.root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || ctx.Err() != nil {
			return nil
		}
		if entry.IsDir() || !strings.EqualFold(entry.Name(), wanted) {
			return nil
		}
		info, statErr := entry.Info()
		if statErr == nil && info.ModTime().UnixNano() >= selectedMtime {
			selected, selectedMtime = path, info.ModTime().UnixNano()
		}
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if selected == "" {
		return nil, ErrStateUnavailable
	}
	bytes, err := os.ReadFile(selected)
	if err != nil {
		return nil, err
	}
	return parseUbisoftSpool(bytes)
}

func parseUbisoftSpool(bytes []byte) (Snapshot, error) {
	result := make(Snapshot)
	for offset := 0; offset < len(bytes); {
		tag, next, ok := readVarint(bytes, offset, len(bytes))
		if !ok {
			return nil, fmt.Errorf("truncated spool tag")
		}
		offset = next
		field, wire := tag>>3, tag&7
		if field == 1 && wire == 2 {
			length, afterLength, valid := readVarint(bytes, offset, len(bytes))
			if !valid || length > uint64(len(bytes)-afterLength) {
				return nil, fmt.Errorf("truncated spool record")
			}
			end := afterLength + int(length)
			achievement, achievementOK := findVarint(bytes, 1, afterLength, end, 0)
			timestamp, timestampOK := findVarint(bytes, 2, afterLength, end, 0)
			if achievementOK && timestampOK && achievement > 0 && timestamp > 0 {
				if timestamp >= 10_000_000_000 {
					timestamp /= 1000
				}
				result[strconv.FormatUint(achievement, 10)] = AchievementState{Unlocked: true, Timestamp: int64(timestamp)}
			}
			offset = end
			continue
		}
		var valid bool
		offset, valid = skipWire(bytes, offset, wire, len(bytes))
		if !valid {
			return nil, fmt.Errorf("invalid spool wire type")
		}
	}
	return result, nil
}

func findVarint(bytes []byte, target uint64, start, end, depth int) (uint64, bool) {
	for offset := start; offset < end; {
		tag, next, ok := readVarint(bytes, offset, end)
		if !ok {
			return 0, false
		}
		offset = next
		field, wire := tag>>3, tag&7
		if wire == 0 {
			value, after, valid := readVarint(bytes, offset, end)
			if !valid {
				return 0, false
			}
			offset = after
			if field == target {
				return value, true
			}
			continue
		}
		if wire == 2 {
			length, afterLength, valid := readVarint(bytes, offset, end)
			if !valid || length > uint64(end-afterLength) {
				return 0, false
			}
			payloadEnd := afterLength + int(length)
			if depth < 4 {
				if value, found := findVarint(bytes, target, afterLength, payloadEnd, depth+1); found {
					return value, true
				}
			}
			offset = payloadEnd
			continue
		}
		var valid bool
		offset, valid = skipWire(bytes, offset, wire, end)
		if !valid {
			return 0, false
		}
	}
	return 0, false
}

func readVarint(bytes []byte, start, end int) (uint64, int, bool) {
	var value uint64
	for offset, shift := start, uint(0); offset < end && shift < 70; offset, shift = offset+1, shift+7 {
		current := bytes[offset]
		value |= uint64(current&0x7f) << shift
		if current&0x80 == 0 {
			return value, offset + 1, true
		}
	}
	return 0, start, false
}

func skipWire(bytes []byte, offset int, wire uint64, end int) (int, bool) {
	switch wire {
	case 0:
		_, next, ok := readVarint(bytes, offset, end)
		return next, ok
	case 1:
		offset += 8
	case 2:
		length, next, ok := readVarint(bytes, offset, end)
		if !ok || length > uint64(end-next) {
			return offset, false
		}
		offset = next + int(length)
	case 5:
		offset += binary.Size(uint32(0))
	default:
		return offset, false
	}
	return offset, offset <= end
}
