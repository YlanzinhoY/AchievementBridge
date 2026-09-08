package googledrive

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"strings"
)

const (
	defaultAPIBaseURL    = "https://www.googleapis.com/drive/v3"
	defaultUploadBaseURL = "https://www.googleapis.com/upload/drive/v3"
)

type File struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	ModifiedTime string `json:"modifiedTime"`
	Size         string `json:"size"`
}

type Client struct {
	httpClient    *http.Client
	accessToken   string
	apiBaseURL    string
	uploadBaseURL string
}

func New(httpClient *http.Client, accessToken string) *Client {
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	return &Client{
		httpClient:    httpClient,
		accessToken:   strings.TrimSpace(accessToken),
		apiBaseURL:    defaultAPIBaseURL,
		uploadBaseURL: defaultUploadBaseURL,
	}
}

func (c *Client) FindAppDataFile(ctx context.Context, name string) (*File, error) {
	query := url.Values{}
	query.Set("spaces", "appDataFolder")
	query.Set("fields", "files(id,name,modifiedTime,size)")
	query.Set("pageSize", "1")
	query.Set("q", fmt.Sprintf("name = '%s' and trashed = false", escapeQueryValue(name)))

	var response struct {
		Files []File `json:"files"`
	}
	if err := c.doJSON(ctx, http.MethodGet, c.apiBaseURL+"/files?"+query.Encode(), nil, "", &response); err != nil {
		return nil, err
	}
	if len(response.Files) == 0 {
		return nil, nil
	}
	return &response.Files[0], nil
}

func (c *Client) UploadAppData(ctx context.Context, name string, content []byte) (File, error) {
	existing, err := c.FindAppDataFile(ctx, name)
	if err != nil {
		return File{}, err
	}
	if existing != nil {
		endpoint := fmt.Sprintf("%s/files/%s?uploadType=media&fields=id,name,modifiedTime,size", c.uploadBaseURL, url.PathEscape(existing.ID))
		var uploaded File
		if err := c.doJSON(ctx, http.MethodPatch, endpoint, bytes.NewReader(content), "application/x-ndjson", &uploaded); err != nil {
			return File{}, err
		}
		if uploaded.ID == "" {
			uploaded.ID = existing.ID
		}
		if uploaded.Name == "" {
			uploaded.Name = name
		}
		return uploaded, nil
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	metadataHeader := make(map[string][]string)
	metadataHeader["Content-Type"] = []string{"application/json; charset=UTF-8"}
	metadata, err := writer.CreatePart(textproto.MIMEHeader(metadataHeader))
	if err != nil {
		return File{}, err
	}
	if err := json.NewEncoder(metadata).Encode(map[string]any{
		"name":    name,
		"parents": []string{"appDataFolder"},
	}); err != nil {
		return File{}, err
	}
	contentHeader := make(map[string][]string)
	contentHeader["Content-Type"] = []string{"application/x-ndjson"}
	contentPart, err := writer.CreatePart(textproto.MIMEHeader(contentHeader))
	if err != nil {
		return File{}, err
	}
	if _, err := contentPart.Write(content); err != nil {
		return File{}, err
	}
	if err := writer.Close(); err != nil {
		return File{}, err
	}

	endpoint := c.uploadBaseURL + "/files?uploadType=multipart&fields=id,name,modifiedTime,size"
	var uploaded File
	if err := c.doJSON(ctx, http.MethodPost, endpoint, &body, writer.FormDataContentType(), &uploaded); err != nil {
		return File{}, err
	}
	return uploaded, nil
}

func (c *Client) doJSON(ctx context.Context, method string, endpoint string, body io.Reader, contentType string, output any) error {
	if c.accessToken == "" {
		return fmt.Errorf("Google Drive access token is not configured")
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+c.accessToken)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 8*1024))
		return fmt.Errorf("Google Drive returned %s: %s", response.Status, strings.TrimSpace(string(message)))
	}
	if output == nil || response.StatusCode == http.StatusNoContent {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1024*1024)).Decode(output); err != nil {
		return fmt.Errorf("decode Google Drive response: %w", err)
	}
	return nil
}

func escapeQueryValue(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	return strings.ReplaceAll(value, "'", "\\'")
}
