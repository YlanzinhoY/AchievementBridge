package core

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync/atomic"
	"time"
)

const ProtocolVersion = 1

type Client struct {
	address  string
	sequence atomic.Uint64
}

type RemoteError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *RemoteError) Error() string {
	if e.Message == "" || e.Message == e.Code {
		return e.Code
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

type request struct {
	Version int    `json:"version"`
	ID      string `json:"id"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

type response struct {
	Version int             `json:"version"`
	ID      string          `json:"id"`
	OK      bool            `json:"ok"`
	Result  json.RawMessage `json:"result"`
	Error   *RemoteError    `json:"error"`
}

func NewClient(address string) *Client {
	return &Client{address: address}
}

func (c *Client) Call(ctx context.Context, method string, params any, result any) error {
	id := fmt.Sprintf("%d-%d", time.Now().UnixMilli(), c.sequence.Add(1))
	payload, err := json.Marshal(request{
		Version: ProtocolVersion,
		ID:      id,
		Method:  method,
		Params:  params,
	})
	if err != nil {
		return fmt.Errorf("encode core request: %w", err)
	}

	connection, err := (&net.Dialer{}).DialContext(ctx, "tcp", c.address)
	if err != nil {
		return fmt.Errorf("connect to Zig core: %w", err)
	}
	defer connection.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := connection.SetDeadline(deadline); err != nil {
			return fmt.Errorf("set core deadline: %w", err)
		}
	}
	if _, err := connection.Write(append(payload, '\n')); err != nil {
		return fmt.Errorf("send core request: %w", err)
	}

	line, err := bufio.NewReaderSize(connection, 64*1024).ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read core response: %w", err)
	}
	var envelope response
	if err := json.Unmarshal(line, &envelope); err != nil {
		return fmt.Errorf("decode core response: %w", err)
	}
	if envelope.Version != ProtocolVersion || envelope.ID != id {
		return fmt.Errorf("invalid core response envelope")
	}
	if !envelope.OK {
		if envelope.Error != nil {
			return envelope.Error
		}
		return fmt.Errorf("core request failed")
	}
	if result == nil {
		return nil
	}
	if err := json.Unmarshal(envelope.Result, result); err != nil {
		return fmt.Errorf("decode core result: %w", err)
	}
	return nil
}
