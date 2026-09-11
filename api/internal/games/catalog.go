package games

import (
	"bufio"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type Installed struct {
	AppID      uint32
	Name       string
	InstallDir string
}

type Catalog struct {
	SteamRoot string
	Apps      []Installed
}

var quotedPair = regexp.MustCompile(`"([^"]+)"\s+"([^"]*)"`)

func Discover(explicitRoot string) (Catalog, error) {
	steamRoot, err := FindSteamRoot(explicitRoot)
	if err != nil {
		return Catalog{}, err
	}
	libraries := []string{steamRoot}
	libraryFile := filepath.Join(steamRoot, "steamapps", "libraryfolders.vdf")
	if bytes, readErr := os.ReadFile(libraryFile); readErr == nil {
		for _, match := range quotedPair.FindAllStringSubmatch(string(bytes), -1) {
			if len(match) == 3 && strings.EqualFold(match[1], "path") {
				libraries = appendUniquePath(libraries, strings.ReplaceAll(match[2], `\\`, `\`))
			}
		}
	}

	apps := make(map[uint32]Installed)
	for _, library := range libraries {
		manifests, _ := filepath.Glob(filepath.Join(library, "steamapps", "appmanifest_*.acf"))
		for _, manifest := range manifests {
			fields, parseErr := parseManifest(manifest)
			if parseErr != nil {
				continue
			}
			id64, parseErr := strconv.ParseUint(fields["appid"], 10, 32)
			if parseErr != nil || id64 == 0 || fields["installdir"] == "" {
				continue
			}
			appID := uint32(id64)
			apps[appID] = Installed{
				AppID:      appID,
				Name:       fields["name"],
				InstallDir: filepath.Join(library, "steamapps", "common", fields["installdir"]),
			}
		}
	}
	result := Catalog{SteamRoot: steamRoot, Apps: make([]Installed, 0, len(apps))}
	for _, app := range apps {
		result.Apps = append(result.Apps, app)
	}
	sort.Slice(result.Apps, func(left, right int) bool { return result.Apps[left].AppID < result.Apps[right].AppID })
	return result, nil
}

func FindSteamRoot(explicit string) (string, error) {
	if explicit != "" {
		return filepath.Clean(explicit), nil
	}
	if env := os.Getenv("STEAM_ROOT"); env != "" {
		return filepath.Clean(env), nil
	}
	if output, err := exec.Command("reg", "query", `HKCU\Software\Valve\Steam`, "/v", "SteamPath").Output(); err == nil {
		for _, line := range strings.Split(string(output), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 3 && strings.EqualFold(fields[0], "SteamPath") {
				return filepath.Clean(strings.Join(fields[2:], " ")), nil
			}
		}
	}
	for _, candidate := range []string{`C:\steam`, `C:\Program Files (x86)\Steam`, `C:\Program Files\Steam`} {
		if _, err := os.Stat(filepath.Join(candidate, "steam.exe")); err == nil {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("Steam installation was not found")
}

func (c Catalog) FindByExecutable(executable string) (Installed, bool) {
	executable = filepath.Clean(executable)
	bestLength := 0
	var best Installed
	for _, app := range c.Apps {
		root := filepath.Clean(app.InstallDir)
		if len(root) <= bestLength || !pathContains(root, executable) {
			continue
		}
		best, bestLength = app, len(root)
	}
	return best, bestLength > 0
}

func pathContains(root, candidate string) bool {
	root = strings.TrimRight(filepath.Clean(root), `\/`)
	candidate = filepath.Clean(candidate)
	if len(candidate) <= len(root) || !strings.EqualFold(candidate[:len(root)], root) {
		return false
	}
	return os.IsPathSeparator(candidate[len(root)])
}

func parseManifest(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	result := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		for _, match := range quotedPair.FindAllStringSubmatch(scanner.Text(), -1) {
			if len(match) == 3 {
				result[strings.ToLower(match[1])] = strings.ReplaceAll(match[2], `\\`, `\`)
			}
		}
	}
	return result, scanner.Err()
}

func appendUniquePath(values []string, value string) []string {
	for _, existing := range values {
		if strings.EqualFold(filepath.Clean(existing), filepath.Clean(value)) {
			return values
		}
	}
	return append(values, value)
}

type Runtime struct {
	Provider   string
	Confidence uint8
}

func DetectRuntime(game Installed) []Runtime {
	scores := make(map[string]int)
	_ = filepath.WalkDir(game.InstallDir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if entry != nil && entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.IsDir() {
			relative, _ := filepath.Rel(game.InstallDir, path)
			if relative != "." && strings.Count(relative, string(os.PathSeparator)) >= 15 {
				return filepath.SkipDir
			}
			return nil
		}
		name := strings.ToLower(entry.Name())
		relative, _ := filepath.Rel(game.InstallDir, path)
		depth := strings.Count(relative, string(os.PathSeparator))
		switch name {
		case "steam_api64.dll", "steam_api.dll":
			scores["steam"] += 55
		case "configs.main.ini", "configs.user.ini", "configs.app.ini":
			if depth < 5 {
				scores["gse"] += 32
			}
		case "force_account_name.txt", "local_save.txt":
			if depth < 5 {
				scores["gse"] += 45
			}
		case "steam_emu.ini":
			if depth < 5 {
				scores["rune"] += 70
			}
		case "steamclient64.dll":
			if depth < 5 {
				scores["rune"] += 20
			}
		case "socialclub_emu.ini":
			if depth < 5 {
				scores["rockstar"] += 80
			}
		case "rune64.dll", "socialclub.dll":
			if depth < 5 {
				scores["rockstar"] += 20
			}
		case "title.rgl":
			if depth < 5 {
				scores["rockstar"] += 15
			}
		case "uplay_r2_loader64.dll", "uplay_r2_loader.dll":
			if depth < 5 {
				scores["uplay_r2"] += 90
			}
		case "upc_r2_loader64.dll", "upc_r2_loader.dll":
			if depth < 5 {
				scores["ubisoft"] += 90
			}
		}
		return nil
	})
	if scores["gse"] > 0 {
		scores["gse"] += 35
		if scores["steam"] > 0 {
			scores["steam"] = min(scores["steam"], 45)
		}
	}
	if scores["rune"] >= 70 {
		scores["rune"] += 20
		if scores["steam"] > 0 {
			scores["steam"] = min(scores["steam"], 45)
		}
	}
	if scores["rockstar"] >= 80 {
		if scores["steam"] > 0 {
			scores["steam"] = min(scores["steam"], 45)
		}
	}
	result := make([]Runtime, 0, len(scores))
	for provider, score := range scores {
		if score > 100 {
			score = 100
		}
		result = append(result, Runtime{Provider: provider, Confidence: uint8(score)})
	}
	sort.Slice(result, func(left, right int) bool { return result[left].Confidence > result[right].Confidence })
	return result
}

func min(left, right int) int {
	if left < right {
		return left
	}
	return right
}
