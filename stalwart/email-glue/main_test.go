package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestClientStalwartErrorMapsFieldAlreadyExists(t *testing.T) {
	status, payload := clientStalwartError(&stalwartAPIError{
		Op:     "create principal",
		Status: http.StatusConflict,
		Code:   "fieldAlreadyExists",
	})

	if status != http.StatusConflict {
		t.Fatalf("status = %d, want %d", status, http.StatusConflict)
	}
	if got := payload["error"]; got != "account_exists" {
		t.Fatalf("error = %v, want account_exists", got)
	}
	if got := payload["reason"]; got != "fieldAlreadyExists" {
		t.Fatalf("reason = %v, want fieldAlreadyExists", got)
	}
}

func TestClientStalwartErrorMapsUnavailable(t *testing.T) {
	status, payload := clientStalwartError(&stalwartAPIError{
		Op:  "create principal",
		Err: errors.New("connection refused"),
	})

	if status != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", status, http.StatusServiceUnavailable)
	}
	if got := payload["error"]; got != "mail_service_unavailable" {
		t.Fatalf("error = %v, want mail_service_unavailable", got)
	}
}

func TestWithPrincipalIdentifiersFallsBackToName(t *testing.T) {
	client := &stalwartClient{}
	var tried []string

	err := client.withPrincipalIdentifiers("patch principal", principalRef{
		ID:   "42",
		Name: "alice",
	}, func(identifier string) error {
		tried = append(tried, identifier)
		if identifier == "42" {
			return &stalwartAPIError{
				Op:     "patch principal",
				Status: http.StatusNotFound,
				Code:   "notFound",
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("withPrincipalIdentifiers returned error: %v", err)
	}
	if len(tried) != 2 || tried[0] != "42" || tried[1] != "alice" {
		t.Fatalf("tried = %v, want [42 alice]", tried)
	}
}

func TestWithPrincipalIdentifiersReturnsNotFoundAfterAllCandidates(t *testing.T) {
	client := &stalwartClient{}

	err := client.withPrincipalIdentifiers("patch principal", principalRef{
		ID:   "42",
		Name: "alice",
	}, func(identifier string) error {
		return &stalwartAPIError{
			Op:     "patch principal",
			Status: http.StatusNotFound,
			Code:   "notFound",
		}
	})
	if err == nil {
		t.Fatal("withPrincipalIdentifiers returned nil error")
	}
	if !isStalwartErrorCode(err, "notFound") {
		t.Fatalf("error = %v, want notFound", err)
	}
}

func TestDecodeStalwartWebhookEventsAcceptsSupportedShapes(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{
			name: "wrapped",
			body: `{"events":[{"id":"event/1","type":"message-ingest.ham","data":{}}]}`,
		},
		{
			name: "array",
			body: `[{"id":"event/1","type":"message-ingest.ham","data":{}}]`,
		},
		{
			name: "single",
			body: `{"id":"event/1","type":"message-ingest.ham","data":{}}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			events, err := decodeStalwartWebhookEvents([]byte(tc.body))
			if err != nil {
				t.Fatalf("decodeStalwartWebhookEvents returned error: %v", err)
			}
			if len(events) != 1 {
				t.Fatalf("events = %d, want 1", len(events))
			}
			if events[0].Type != "message-ingest.ham" {
				t.Fatalf("type = %q, want message-ingest.ham", events[0].Type)
			}
		})
	}
}

func testMailPushConfig(ejabberdAPIBase string) *Config {
	return &Config{
		Domain:             "example.com",
		RequireClientToken: true,
		ClientToken:        "client-token",
		MailPush:           true,
		MailPushEventTypes: []string{"message-ingest.ham"},
		EjabberdAPIBase:    ejabberdAPIBase,
		MailNotifyJID:      "mail-notify@example.com",
		StalwartHookToken:  "hook-token",
	}
}

func newHookTestServer(srv *server) *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/hooks/stalwart/events", srv.stalwartEventsHook)
	mux.HandleFunc("/hooks/stalwart/events/", srv.stalwartEventsHook)
	return httptest.NewServer(withMiddleware(srv, mux))
}

func postHook(t *testing.T, url, bearer, body string, headers map[string]string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url+"/hooks/stalwart/events", bytes.NewBufferString(body))
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	return resp.StatusCode, respBody
}

func responseSent(t *testing.T, body []byte) int {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("response json: %v\nbody=%s", err, string(body))
	}
	got, ok := payload["sent"].(float64)
	if !ok {
		t.Fatalf("sent = %T %v, want number", payload["sent"], payload["sent"])
	}
	return int(got)
}

func TestStalwartEventsHookSendsMailPushStanza(t *testing.T) {
	var sent []map[string]any
	ejabberd := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		if r.URL.Path != "/api/send_stanza" {
			t.Errorf("path = %s, want /api/send_stanza", r.URL.Path)
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Errorf("decode ejabberd payload: %v", err)
		}
		sent = append(sent, payload)
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "success"})
	}))
	defer ejabberd.Close()

	srv := &server{
		cfg:      testMailPushConfig(ejabberd.URL + "/api"),
		stalwart: &stalwartClient{},
	}
	hook := newHookTestServer(srv)
	defer hook.Close()

	status, body := postHook(t, hook.URL, "hook-token", `{
		"events": [{
			"id": "event/1",
			"type": "message-ingest.ham",
			"data": {"envelope": {"to": "Alice <alice@example.com>"}}
		}]
	}`, nil)
	if status != http.StatusOK {
		t.Fatalf("status = %d body=%s, want 200", status, string(body))
	}
	if got := responseSent(t, body); got != 1 {
		t.Fatalf("sent = %d, want 1", got)
	}
	if len(sent) != 1 {
		t.Fatalf("send_stanza calls = %d, want 1", len(sent))
	}
	if got := sent[0]["from"]; got != "mail-notify@example.com" {
		t.Fatalf("from = %v, want mail-notify@example.com", got)
	}
	if got := sent[0]["to"]; got != "alice@example.com" {
		t.Fatalf("to = %v, want alice@example.com", got)
	}
	stanza, ok := sent[0]["stanza"].(string)
	if !ok {
		t.Fatalf("stanza = %T, want string", sent[0]["stanza"])
	}
	if !strings.Contains(stanza, "urn:axichat:mail-push:0") {
		t.Fatalf("stanza missing mail-push namespace: %s", stanza)
	}
	if !strings.Contains(stanza, "<body>New email</body>") {
		t.Fatalf("stanza missing generic body: %s", stanza)
	}
}

func TestStalwartEventsHookRequiresBearerToken(t *testing.T) {
	srv := &server{
		cfg:      testMailPushConfig("http://127.0.0.1:1/api"),
		stalwart: &stalwartClient{},
	}
	hook := newHookTestServer(srv)
	defer hook.Close()

	for _, tc := range []struct {
		name   string
		bearer string
	}{
		{name: "missing"},
		{name: "wrong", bearer: "wrong-token"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, _ := postHook(t, hook.URL, tc.bearer, `{"id":"event/1","type":"message-ingest.ham","data":{}}`, nil)
			if status != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", status)
			}
		})
	}
}

func TestStalwartEventsHookDisabledReturnsNotFound(t *testing.T) {
	cfg := testMailPushConfig("http://127.0.0.1:1/api")
	cfg.MailPush = false
	srv := &server{
		cfg:      cfg,
		stalwart: &stalwartClient{},
	}
	hook := newHookTestServer(srv)
	defer hook.Close()

	status, _ := postHook(t, hook.URL, "hook-token", `{"id":"event/1","type":"message-ingest.ham","data":{}}`, nil)
	if status != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", status)
	}
}

func TestStalwartEventsHookIgnoresSpamByDefault(t *testing.T) {
	sendCalls := 0
	ejabberd := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sendCalls++
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "success"})
	}))
	defer ejabberd.Close()

	srv := &server{
		cfg:      testMailPushConfig(ejabberd.URL + "/api"),
		stalwart: &stalwartClient{},
	}
	hook := newHookTestServer(srv)
	defer hook.Close()

	status, body := postHook(t, hook.URL, "hook-token", `{
		"id": "event/1",
		"type": "message-ingest.spam",
		"data": {"to": "alice@example.com"}
	}`, nil)
	if status != http.StatusOK {
		t.Fatalf("status = %d body=%s, want 200", status, string(body))
	}
	if got := responseSent(t, body); got != 0 {
		t.Fatalf("sent = %d, want 0", got)
	}
	if sendCalls != 0 {
		t.Fatalf("send_stanza calls = %d, want 0", sendCalls)
	}
}

func TestStalwartEventsHookAcceptsConfiguredExtraEventType(t *testing.T) {
	sendCalls := 0
	ejabberd := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sendCalls++
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "success"})
	}))
	defer ejabberd.Close()

	cfg := testMailPushConfig(ejabberd.URL + "/api")
	cfg.MailPushEventTypes = []string{"message-ingest.ham", "message-ingest.spam"}
	srv := &server{
		cfg:      cfg,
		stalwart: &stalwartClient{},
	}
	hook := newHookTestServer(srv)
	defer hook.Close()

	status, body := postHook(t, hook.URL, "hook-token", `{
		"id": "event/1",
		"type": "message-ingest.spam",
		"data": {"recipients": ["alice@example.com"]}
	}`, nil)
	if status != http.StatusOK {
		t.Fatalf("status = %d body=%s, want 200", status, string(body))
	}
	if got := responseSent(t, body); got != 1 {
		t.Fatalf("sent = %d, want 1", got)
	}
	if sendCalls != 1 {
		t.Fatalf("send_stanza calls = %d, want 1", sendCalls)
	}
}

func TestLocalRecipientsForWebhookEventFallsBackToAccountIdentifier(t *testing.T) {
	stalwart := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/api/principal" {
			t.Errorf("path = %s, want /api/principal", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer api-token" {
			t.Errorf("Authorization = %q, want bearer token", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"items": []map[string]any{
					{
						"id":     "42",
						"name":   "alice",
						"emails": []string{"alice@example.com", "alice@other.test"},
					},
				},
			},
		})
	}))
	defer stalwart.Close()

	cfg := testMailPushConfig("http://127.0.0.1:1/api")
	cfg.StalwartAPIBase = stalwart.URL + "/api"
	cfg.StalwartAPIToken = "api-token"
	srv := &server{
		cfg:      cfg,
		stalwart: newStalwartClient(cfg),
	}

	recipients := srv.localRecipientsForWebhookEvent(stalwartWebhookEvent{
		ID:   "event/1",
		Type: "message-ingest.ham",
		Data: map[string]any{
			"accountId": "42",
		},
	})
	if len(recipients) != 1 || recipients[0] != "alice@example.com" {
		t.Fatalf("recipients = %v, want [alice@example.com]", recipients)
	}
}

func TestStalwartHookBypassesPublicTokenButRequiresBearer(t *testing.T) {
	srv := &server{
		cfg:      testMailPushConfig("http://127.0.0.1:1/api"),
		stalwart: &stalwartClient{},
	}
	hook := newHookTestServer(srv)
	defer hook.Close()

	status, body := postHook(t, hook.URL, "hook-token", `{"id":"event/1","type":"message-ingest.ham","data":{}}`, nil)
	if status != http.StatusOK {
		t.Fatalf("status without public token = %d body=%s, want 200", status, string(body))
	}

	status, _ = postHook(t, hook.URL, "", `{"id":"event/1","type":"message-ingest.ham","data":{}}`, map[string]string{
		"X-Client-Token": "client-token",
	})
	if status != http.StatusUnauthorized {
		t.Fatalf("status with public token but no bearer = %d, want 401", status)
	}
}
