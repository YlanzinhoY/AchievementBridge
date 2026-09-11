package events

import (
	"bytes"
	"sync"
)

type Broker struct {
	mu          sync.Mutex
	history     []string
	maxHistory  int
	subscribers map[chan string]struct{}
}

func NewBroker(maxHistory int) *Broker {
	return &Broker{
		maxHistory:  maxHistory,
		subscribers: make(map[chan string]struct{}),
	}
}

func (b *Broker) Publish(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.maxHistory >= 0 {
		b.history = append(b.history, line)
		if b.maxHistory > 0 && len(b.history) > b.maxHistory {
			copy(b.history, b.history[len(b.history)-b.maxHistory:])
			b.history = b.history[:b.maxHistory]
		}
	}
	for subscriber := range b.subscribers {
		select {
		case subscriber <- line:
		default:
		}
	}
}

func (b *Broker) ClearHistory() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.history = nil
}

func (b *Broker) Subscribe() (<-chan string, []string, func()) {
	b.mu.Lock()
	defer b.mu.Unlock()
	channel := make(chan string, 128)
	b.subscribers[channel] = struct{}{}
	history := append([]string(nil), b.history...)
	return channel, history, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if _, ok := b.subscribers[channel]; ok {
			delete(b.subscribers, channel)
			close(channel)
		}
	}
}

type LineWriter struct {
	mu      sync.Mutex
	buffer  []byte
	publish func(string)
}

func NewLineWriter(publish func(string)) *LineWriter {
	return &LineWriter{publish: publish}
}

func (w *LineWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buffer = append(w.buffer, data...)
	for {
		index := bytes.IndexByte(w.buffer, '\n')
		if index < 0 {
			break
		}
		line := string(bytes.TrimSuffix(w.buffer[:index], []byte{'\r'}))
		w.buffer = w.buffer[index+1:]
		w.publish(line)
	}
	return len(data), nil
}
