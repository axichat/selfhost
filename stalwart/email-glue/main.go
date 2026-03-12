package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Domain           string
	StalwartAPIBase  string
	StalwartAPIToken string

	// DefaultQuotaBytes is the value sent in the Stalwart principal's "quota" field.
	// Per Stalwart docs this is measured in bytes. 0 means unlimited.
	DefaultQuotaBytes int64

	ListenAddr string

	CertFile string
	KeyFile  string

	// Public client token: meant to prevent blind / unauthenticated internet scanning
	// of provisioning endpoints. It is not meant to withstand targeted compromise.
	RequireClientToken bool
	ClientToken        string
	ClientTokenFile    string
}

func getenv(key, def string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	return v
}

func getenvInt64(key string, def int64) (int64, error) {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def, nil
	}
	i, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer: %w", key, err)
	}
	return i, nil
}

func getenvBool(key string, def bool) (bool, error) {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if v == "" {
		return def, nil
	}
	switch v {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("%s must be a boolean (1/0, true/false, yes/no)", key)
	}
}

func loadOrGenerateClientToken(tokenFile string) (string, bool, error) {
	// Returns (token, generated, err)
	b, err := os.ReadFile(tokenFile)
	if err == nil {
		t := strings.TrimSpace(string(b))
		if t != "" {
			return t, false, nil
		}
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", false, err
	}

	// Generate a URL-safe token (48 bytes => 64 chars base64url-ish)
	raw := make([]byte, 48)
	if _, err := rand.Read(raw); err != nil {
		return "", false, fmt.Errorf("rand: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)

	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(tokenFile), 0750); err != nil {
		return "", false, err
	}

	// Best-effort atomic write
	tmp := tokenFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(token+"\n"), 0600); err != nil {
		return "", false, err
	}
	if err := os.Rename(tmp, tokenFile); err != nil {
		return "", false, err
	}

	return token, true, nil
}

func loadConfig() (*Config, error) {
	domain := strings.TrimSpace(os.Getenv("EMAIL_DOMAIN"))
	if domain == "" {
		return nil, fmt.Errorf("EMAIL_DOMAIN is required")
	}
	apiBase := getenv("STALWART_API", "http://127.0.0.1:8080/api")
	apiToken := strings.TrimSpace(os.Getenv("STALWART_API_TOKEN"))
	if apiToken == "" {
		return nil, errors.New("STALWART_API_TOKEN is required")
	}

	quota, err := getenvInt64("EMAIL_GLUE_DEFAULT_QUOTA_BYTES", 0) // 0 means unlimited
	if err != nil {
		return nil, err
	}

	listenAddr := getenv("EMAIL_GLUE_LISTEN", "0.0.0.0:8443")
	certFile := getenv("EMAIL_GLUE_CERT_FILE", fmt.Sprintf("/var/lib/stalwart/certs/%s.fullchain.pem", domain))
	keyFile := getenv("EMAIL_GLUE_KEY_FILE", fmt.Sprintf("/var/lib/stalwart/certs/%s.privkey.pem", domain))
	requireClientToken, err := getenvBool("EMAIL_GLUE_REQUIRE_CLIENT_TOKEN", false)
	if err != nil {
		return nil, err
	}

	token := strings.TrimSpace(os.Getenv("EMAIL_GLUE_CLIENT_TOKEN"))
	tokenFile := getenv("EMAIL_GLUE_CLIENT_TOKEN_FILE", "/var/lib/email-glue/client_token")

	if requireClientToken && token == "" {
		t, generated, err := loadOrGenerateClientToken(tokenFile)
		if err != nil {
			return nil, fmt.Errorf("client token: %w", err)
		}
		if generated {
			log.Printf("[email-glue] Generated EMAIL_GLUE_CLIENT_TOKEN and wrote it to %s", tokenFile)
			log.Printf("[email-glue] You must copy this token into your client config (header X-Client-Token).")
		}
		token = t
	}

	cfg := &Config{
		Domain:             domain,
		StalwartAPIBase:    strings.TrimRight(apiBase, "/"),
		StalwartAPIToken:   apiToken,
		DefaultQuotaBytes:  quota,
		ListenAddr:         listenAddr,
		CertFile:           certFile,
		KeyFile:            keyFile,
		RequireClientToken: requireClientToken,
		ClientToken:        token,
		ClientTokenFile:    tokenFile,
	}
	return cfg, nil
}

type certReloader struct {
	certPath string
	keyPath  string

	mu      sync.RWMutex
	lastMod time.Time
	cert    *tls.Certificate
}

func (r *certReloader) GetCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	// Check mtime of both files.
	statC, err := os.Stat(r.certPath)
	if err != nil {
		return nil, err
	}
	statK, err := os.Stat(r.keyPath)
	if err != nil {
		return nil, err
	}
	mod := statC.ModTime()
	if statK.ModTime().After(mod) {
		mod = statK.ModTime()
	}

	r.mu.RLock()
	cached := r.cert
	cachedMod := r.lastMod
	r.mu.RUnlock()

	if cached != nil && !mod.After(cachedMod) {
		return cached, nil
	}

	// Reload
	c, err := tls.LoadX509KeyPair(r.certPath, r.keyPath)
	if err != nil {
		return nil, err
	}

	r.mu.Lock()
	r.cert = &c
	r.lastMod = mod
	r.mu.Unlock()
	return &c, nil
}

// --- Simple token-bucket rate limiter (no external deps) ---

type bucket struct {
	rate  float64 // tokens/sec
	burst float64

	tokens float64
	last   time.Time
}

func (b *bucket) allow(now time.Time) bool {
	if b.last.IsZero() {
		b.last = now
		b.tokens = b.burst
	}
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * b.rate
		if b.tokens > b.burst {
			b.tokens = b.burst
		}
		b.last = now
	}
	if b.tokens >= 1.0 {
		b.tokens -= 1.0
		return true
	}
	return false
}

type bucketEntry struct {
	b        bucket
	lastSeen time.Time
}

type bucketStore struct {
	mu    sync.Mutex
	rate  float64
	burst int
	ttl   time.Duration
	m     map[string]*bucketEntry
}

func newBucketStore(rate float64, burst int, ttl time.Duration) *bucketStore {
	return &bucketStore{
		rate:  rate,
		burst: burst,
		ttl:   ttl,
		m:     make(map[string]*bucketEntry),
	}
}

func (s *bucketStore) allow(key string) bool {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()

	// opportunistic cleanup
	for k, e := range s.m {
		if now.Sub(e.lastSeen) > s.ttl {
			delete(s.m, k)
		}
	}

	e, ok := s.m[key]
	if !ok {
		e = &bucketEntry{
			b: bucket{
				rate:  s.rate,
				burst: float64(s.burst),
			},
			lastSeen: now,
		}
		s.m[key] = e
	}
	e.lastSeen = now
	return e.b.allow(now)
}

type principalRef struct {
	ID   string
	Name string
}

func (p principalRef) IsZero() bool {
	return p.ID == "" && p.Name == ""
}

type stalwartAPIError struct {
	Op     string
	Status int
	Code   string
	Detail string
	Err    error
}

func (e *stalwartAPIError) Error() string {
	parts := []string{fmt.Sprintf("stalwart %s", e.Op)}
	if e.Status > 0 {
		parts = append(parts, fmt.Sprintf("http %d", e.Status))
	}
	if e.Code != "" {
		parts = append(parts, e.Code)
	}
	if e.Detail != "" && e.Detail != e.Code {
		parts = append(parts, e.Detail)
	}
	if e.Err != nil {
		parts = append(parts, e.Err.Error())
	}
	return strings.Join(parts, ": ")
}

func stringValue(v any) string {
	s, _ := v.(string)
	return strings.TrimSpace(s)
}

func extractStalwartError(js map[string]any, body []byte) (string, string) {
	code := ""
	detail := strings.TrimSpace(string(body))

	if js != nil {
		if v, ok := js["error"]; ok {
			code = stringValue(v)
		}
		if detail == "" {
			if v, ok := js["details"]; ok {
				detail = stringValue(v)
			}
		}
		if detail == "" {
			if v, ok := js["detail"]; ok {
				detail = stringValue(v)
			}
		}
		if detail == "" {
			if v, ok := js["reason"]; ok {
				detail = stringValue(v)
			}
		}
	}

	return code, detail
}

func newStalwartAPIError(op string, status int, body []byte, js map[string]any, err error) error {
	code, detail := extractStalwartError(js, body)
	if err == nil && status < 400 && code == "" {
		return nil
	}
	return &stalwartAPIError{
		Op:     op,
		Status: status,
		Code:   code,
		Detail: detail,
		Err:    err,
	}
}

func isStalwartErrorCode(err error, code string) bool {
	var apiErr *stalwartAPIError
	return errors.As(err, &apiErr) && apiErr.Code == code
}

func clientStalwartError(err error) (int, map[string]any) {
	status := http.StatusBadGateway
	code := "mail_backend_error"

	var apiErr *stalwartAPIError
	if errors.As(err, &apiErr) {
		switch apiErr.Code {
		case "fieldAlreadyExists":
			status = http.StatusConflict
			code = "account_exists"
		case "notFound":
			status = http.StatusNotFound
			code = "not_found"
		case "forbidden", "unauthorized":
			status = http.StatusBadGateway
			code = "mail_backend_auth_error"
		default:
			switch apiErr.Status {
			case http.StatusUnauthorized, http.StatusForbidden:
				status = http.StatusBadGateway
				code = "mail_backend_auth_error"
			case http.StatusConflict:
				status = http.StatusConflict
				code = "account_conflict"
			default:
				if apiErr.Err != nil || apiErr.Status >= 500 {
					status = http.StatusServiceUnavailable
					code = "mail_service_unavailable"
				}
			}
		}
	}

	payload := map[string]any{"error": code}
	if apiErr != nil && apiErr.Code != "" {
		payload["reason"] = apiErr.Code
	}
	return status, payload
}

func uniqueNonEmpty(values ...string) []string {
	var out []string
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		seen := false
		for _, existing := range out {
			if existing == value {
				seen = true
				break
			}
		}
		if !seen {
			out = append(out, value)
		}
	}
	return out
}

// --- Stalwart API helpers ---

type stalwartClient struct {
	base  string
	token string
	http  *http.Client
}

func newStalwartClient(cfg *Config) *stalwartClient {
	return &stalwartClient{
		base:  cfg.StalwartAPIBase,
		token: cfg.StalwartAPIToken,
		http: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

func (c *stalwartClient) doJSON(req *http.Request, out any) (int, []byte, error) {
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	if req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20)) // 1 MiB
	if out != nil && len(body) > 0 {
		_ = json.Unmarshal(body, out) // best-effort
	}
	return resp.StatusCode, body, nil
}

func (c *stalwartClient) createUser(localpart, email, passwordHash string, quota int64) error {
	payload := map[string]any{
		"type":        "individual",
		"name":        localpart,
		"quota":       quota,
		"description": fmt.Sprintf("Mail account %s", email),
		"secrets":     []string{passwordHash},
		"emails":      []string{email},
		"roles":       []string{"user"},
	}

	b, _ := json.Marshal(payload)
	req, _ := http.NewRequest("POST", c.base+"/principal", bytes.NewReader(b))
	var js map[string]any
	status, body, err := c.doJSON(req, &js)
	if apiErr := newStalwartAPIError("create principal", status, body, js, err); apiErr != nil {
		return apiErr
	}
	return nil
}

func normalizeEmails(v any) []string {
	switch t := v.(type) {
	case nil:
		return nil
	case string:
		if t == "" {
			return nil
		}
		return []string{t}
	case []any:
		out := make([]string, 0, len(t))
		for _, x := range t {
			if s, ok := x.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	default:
		// sometimes JSON unmarshals []string as []any, but handle []string anyway:
		if ss, ok := v.([]string); ok {
			out := make([]string, 0, len(ss))
			for _, s := range ss {
				if s != "" {
					out = append(out, s)
				}
			}
			return out
		}
		return nil
	}
}

func idToString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		// JSON numbers
		return strconv.FormatInt(int64(t), 10)
	case int64:
		return strconv.FormatInt(t, 10)
	case json.Number:
		return t.String()
	default:
		return ""
	}
}

func (c *stalwartClient) findPrincipalByEmail(email string) (principalRef, error) {
	req, _ := http.NewRequest("GET", c.base+"/principal?types=individual&limit=1000", nil)

	var js map[string]any
	status, body, err := c.doJSON(req, &js)
	if apiErr := newStalwartAPIError("list principal", status, body, js, err); apiErr != nil {
		return principalRef{}, apiErr
	}
	if js == nil {
		return principalRef{}, errors.New("stalwart list principal: empty json")
	}

	data, _ := js["data"].(map[string]any)
	itemsAny, _ := data["items"].([]any)

	for _, it := range itemsAny {
		m, ok := it.(map[string]any)
		if !ok {
			continue
		}
		em := normalizeEmails(m["emails"])
		for _, e := range em {
			if e == email {
				id := idToString(m["id"])
				name := stringValue(m["name"])
				if name == "" {
					name, _, _ = strings.Cut(email, "@")
				}
				if id == "" && name == "" {
					return principalRef{}, errors.New("stalwart principal missing id and name")
				}
				return principalRef{ID: id, Name: name}, nil
			}
		}
	}

	return principalRef{}, nil
}

func (c *stalwartClient) withPrincipalIdentifiers(op string, ref principalRef, fn func(string) error) error {
	identifiers := uniqueNonEmpty(ref.ID, ref.Name)
	if len(identifiers) == 0 {
		return &stalwartAPIError{
			Op:     op,
			Status: http.StatusNotFound,
			Code:   "notFound",
		}
	}

	var lastNotFound error
	for _, identifier := range identifiers {
		err := fn(identifier)
		if err == nil {
			return nil
		}
		if isStalwartErrorCode(err, "notFound") {
			lastNotFound = err
			continue
		}
		return err
	}
	if lastNotFound != nil {
		return lastNotFound
	}
	return &stalwartAPIError{
		Op:     op,
		Status: http.StatusNotFound,
		Code:   "notFound",
	}
}

func (c *stalwartClient) deletePrincipal(ref principalRef) error {
	return c.withPrincipalIdentifiers("delete principal", ref, func(identifier string) error {
		req, _ := http.NewRequest("DELETE", c.base+"/principal/"+identifier, nil)
		var js map[string]any
		status, body, err := c.doJSON(req, &js)
		return newStalwartAPIError("delete principal", status, body, js, err)
	})
}

func (c *stalwartClient) setPrincipalPassword(ref principalRef, passwordHash string) error {
	ops := []map[string]any{
		{
			"action": "set",
			"field":  "secrets",
			"value":  passwordHash,
		},
	}
	b, _ := json.Marshal(ops)
	return c.withPrincipalIdentifiers("patch principal", ref, func(identifier string) error {
		req, _ := http.NewRequest("PATCH", c.base+"/principal/"+identifier, bytes.NewReader(b))

		var js map[string]any
		status, body, err := c.doJSON(req, &js)
		return newStalwartAPIError("patch principal", status, body, js, err)
	})
}

// --- Password hashing helper ---

func hashPasswordSHA512Crypt(plain string) (string, error) {
	// Avoid putting passwords in process args; use -stdin.
	cmd := exec.Command("openssl", "passwd", "-6", "-stdin")
	cmd.Stdin = strings.NewReader(plain)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// --- IMAP ownership proof (no external libs) ---

var errIMAPAuthFailed = errors.New("imap auth failed")

func imapLogin(domain, email, password string) error {
	localpart, _, ok := strings.Cut(email, "@")
	if !ok || localpart == "" {
		return errors.New("invalid email address")
	}

	dialer := &net.Dialer{Timeout: 10 * time.Second}
	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
		ServerName: domain, // validate cert for EMAIL_DOMAIN even though we're connecting to 127.0.0.1
	}
	conn, err := tls.DialWithDialer(dialer, "tcp", "127.0.0.1:993", tlsCfg)
	if err != nil {
		return fmt.Errorf("imap dial: %w", err)
	}
	defer conn.Close()

	conn.SetDeadline(time.Now().Add(12 * time.Second))
	r := bufio.NewReader(conn)
	w := bufio.NewWriter(conn)

	// Greeting
	if _, err := r.ReadString('\n'); err != nil {
		return fmt.Errorf("imap greeting: %w", err)
	}

	// LOGIN using IMAP literal for the password to avoid quoting issues.
	tag := "a1"
	pwBytes := []byte(password)
	fmt.Fprintf(w, "%s LOGIN %s {%d}\r\n", tag, localpart, len(pwBytes))
	if err := w.Flush(); err != nil {
		return fmt.Errorf("imap login flush: %w", err)
	}

	// Expect continuation
	line, err := r.ReadString('\n')
	if err != nil {
		return fmt.Errorf("imap continuation: %w", err)
	}
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "+") {
		if strings.HasPrefix(line, tag+" NO") || strings.Contains(line, " NO ") {
			return errIMAPAuthFailed
		}
		return fmt.Errorf("imap continuation rejected: %s", line)
	}

	// Send literal + CRLF
	if _, err := w.Write(pwBytes); err != nil {
		return fmt.Errorf("imap password write: %w", err)
	}
	if _, err := w.WriteString("\r\n"); err != nil {
		return fmt.Errorf("imap password terminator: %w", err)
	}
	if err := w.Flush(); err != nil {
		return fmt.Errorf("imap password flush: %w", err)
	}

	// Read until tagged response
	for i := 0; i < 50; i++ {
		line, err := r.ReadString('\n')
		if err != nil {
			return fmt.Errorf("imap login response: %w", err)
		}
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, tag+" ") {
			// e.g. "a1 OK Logged in"
			if strings.Contains(line, " OK ") || strings.HasPrefix(line, tag+" OK") {
				// Best-effort logout (don't care)
				_, _ = w.WriteString("a2 LOGOUT\r\n")
				_ = w.Flush()
				return nil
			}
			if strings.Contains(line, " NO ") || strings.HasPrefix(line, tag+" NO") {
				return errIMAPAuthFailed
			}
			return fmt.Errorf("imap login rejected: %s", line)
		}
	}
	return errors.New("imap login response not received")
}

// --- HTTP server ---

var localpartRe = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

type server struct {
	cfg      *Config
	stalwart *stalwartClient

	globalRL *bucketStore
	signupRL *bucketStore

	status statusCache
}

type statusCache struct {
	mu       sync.Mutex
	ttl      time.Duration
	lastAt   time.Time
	lastCode int
	lastBody []byte

	inflight bool
	waiters  []chan struct{}
}

func newStatusCache(ttl time.Duration) statusCache {
	return statusCache{ttl: ttl}
}

func (c *statusCache) getOrCompute(parent context.Context, now time.Time, compute func(context.Context) (int, []byte)) (int, []byte) {
	// Fast path: cache hit.
	c.mu.Lock()
	if !c.lastAt.IsZero() && now.Sub(c.lastAt) < c.ttl {
		code := c.lastCode
		body := append([]byte(nil), c.lastBody...)
		c.mu.Unlock()
		return code, body
	}

	// If another request is already refreshing the cache, wait for it.
	if c.inflight {
		ch := make(chan struct{})
		c.waiters = append(c.waiters, ch)
		c.mu.Unlock()
		<-ch
		// Cache should now be populated.
		c.mu.Lock()
		code := c.lastCode
		body := append([]byte(nil), c.lastBody...)
		c.mu.Unlock()
		return code, body
	}

	// Mark inflight and compute.
	c.inflight = true
	c.mu.Unlock()

	ctx, cancel := context.WithTimeout(parent, 6*time.Second)
	defer cancel()
	code, body := compute(ctx)

	// Update cache and release waiters.
	c.mu.Lock()
	c.lastAt = time.Now()
	c.lastCode = code
	c.lastBody = append([]byte(nil), body...)
	c.inflight = false
	for _, ch := range c.waiters {
		close(ch)
	}
	c.waiters = nil
	c.mu.Unlock()

	return code, append([]byte(nil), body...)
}

type simpleStatus struct {
	Stalwart string `json:"stalwart"`
	Ejabberd string `json:"ejabberd"`
}

func stalwartOnline(ctx context.Context, stalwartAPIBase string) bool {
	// Convert e.g. http://127.0.0.1:8080/api => http://127.0.0.1:8080
	root := strings.TrimRight(stalwartAPIBase, "/")
	if u, err := url.Parse(root); err == nil {
		u.Path = ""
		u.RawQuery = ""
		u.Fragment = ""
		root = strings.TrimRight(u.String(), "/")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, root+"/healthz/live", nil)
	if err != nil {
		return false
	}

	hc := &http.Client{Timeout: 2 * time.Second}
	resp, err := hc.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode == 200
}

func ejabberdOnline(ctx context.Context) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://127.0.0.1:5281/api/status", strings.NewReader("{}"))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")

	hc := &http.Client{Timeout: 2 * time.Second}
	resp, err := hc.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode == 200
}

func (s *server) remoteIP(r *http.Request) string {
	// No reverse proxy in front of this service (by design),
	// so use RemoteAddr.
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *server) checkClientToken(r *http.Request) bool {
	// Support both header names for compatibility.
	got := r.Header.Get("X-Client-Token")
	if got == "" {
		got = r.Header.Get("X-Auth-Token")
	}
	want := s.cfg.ClientToken
	if got == "" || want == "" {
		return false
	}
	// Constant-time compare to avoid trivial timing leaks.
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func (s *server) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *server) writeRawJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
	if len(body) == 0 || body[len(body)-1] != '\n' {
		_, _ = w.Write([]byte("\n"))
	}
}

func (s *server) writeStalwartAPIError(w http.ResponseWriter, err error) {
	status, payload := clientStalwartError(err)
	s.writeJSON(w, status, payload)
}

func (s *server) signup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	ip := s.remoteIP(r)

	if !s.globalRL.allow(ip) {
		s.writeJSON(w, 429, map[string]any{"error": "rate_limited"})
		return
	}
	if !s.signupRL.allow(ip) {
		s.writeJSON(w, 429, map[string]any{"error": "rate_limited"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8<<10) // 8 KiB
	var req struct {
		Localpart string `json:"localpart"`
		Username  string `json:"username"`
		Password  string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeJSON(w, 400, map[string]any{"error": "bad_json"})
		return
	}
	localpart := strings.TrimSpace(req.Localpart)
	if localpart == "" {
		localpart = strings.TrimSpace(req.Username)
	}
	password := req.Password

	if localpart == "" || password == "" {
		s.writeJSON(w, 400, map[string]any{"error": "localpart_and_password_required"})
		return
	}
	if !localpartRe.MatchString(localpart) {
		s.writeJSON(w, 400, map[string]any{"error": "invalid_localpart"})
		return
	}
	if len(password) < 8 {
		s.writeJSON(w, 400, map[string]any{"error": "password_too_short"})
		return
	}

	email := fmt.Sprintf("%s@%s", localpart, s.cfg.Domain)
	hash, err := hashPasswordSHA512Crypt(password)
	if err != nil {
		log.Printf("[email-glue] hash password error: %v", err)
		s.writeJSON(w, 500, map[string]any{"error": "internal_error"})
		return
	}

	if err := s.stalwart.createUser(localpart, email, hash, s.cfg.DefaultQuotaBytes); err != nil {
		log.Printf("[email-glue] stalwart createUser error: %v", err)
		s.writeStalwartAPIError(w, err)
		return
	}

	s.writeJSON(w, 201, map[string]any{"email": email})
}

func (s *server) deleteAccount(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	ip := s.remoteIP(r)
	if !s.globalRL.allow(ip) {
		s.writeJSON(w, 429, map[string]any{"error": "rate_limited"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeJSON(w, 400, map[string]any{"error": "bad_json"})
		return
	}
	email := strings.TrimSpace(req.Email)
	password := req.Password
	if email == "" || password == "" {
		s.writeJSON(w, 400, map[string]any{"error": "email_and_password_required"})
		return
	}
	if !strings.HasSuffix(strings.ToLower(email), "@"+strings.ToLower(s.cfg.Domain)) {
		s.writeJSON(w, 400, map[string]any{"error": "wrong_domain"})
		return
	}

	if err := imapLogin(s.cfg.Domain, email, password); err != nil {
		if errors.Is(err, errIMAPAuthFailed) {
			s.writeJSON(w, 401, map[string]any{"error": "auth_failed"})
			return
		}
		log.Printf("[email-glue] imap login error: %v", err)
		s.writeJSON(w, 503, map[string]any{"error": "mail_service_unavailable"})
		return
	}

	ref, err := s.stalwart.findPrincipalByEmail(email)
	if err != nil {
		log.Printf("[email-glue] stalwart findPrincipal error: %v", err)
		s.writeStalwartAPIError(w, err)
		return
	}
	if ref.IsZero() {
		s.writeJSON(w, 404, map[string]any{"error": "not_found"})
		return
	}

	if err := s.stalwart.deletePrincipal(ref); err != nil {
		log.Printf("[email-glue] stalwart deletePrincipal error: %v", err)
		s.writeStalwartAPIError(w, err)
		return
	}

	s.writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *server) changePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	ip := s.remoteIP(r)
	if !s.globalRL.allow(ip) {
		s.writeJSON(w, 429, map[string]any{"error": "rate_limited"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	var req struct {
		Email       string `json:"email"`
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeJSON(w, 400, map[string]any{"error": "bad_json"})
		return
	}
	email := strings.TrimSpace(req.Email)
	if email == "" || req.OldPassword == "" || req.NewPassword == "" {
		s.writeJSON(w, 400, map[string]any{"error": "email_old_new_required"})
		return
	}
	if !strings.HasSuffix(strings.ToLower(email), "@"+strings.ToLower(s.cfg.Domain)) {
		s.writeJSON(w, 400, map[string]any{"error": "wrong_domain"})
		return
	}
	if len(req.NewPassword) < 8 {
		s.writeJSON(w, 400, map[string]any{"error": "new_password_too_short"})
		return
	}

	if err := imapLogin(s.cfg.Domain, email, req.OldPassword); err != nil {
		if errors.Is(err, errIMAPAuthFailed) {
			s.writeJSON(w, 401, map[string]any{"error": "auth_failed"})
			return
		}
		log.Printf("[email-glue] imap login error: %v", err)
		s.writeJSON(w, 503, map[string]any{"error": "mail_service_unavailable"})
		return
	}

	ref, err := s.stalwart.findPrincipalByEmail(email)
	if err != nil {
		log.Printf("[email-glue] stalwart findPrincipal error: %v", err)
		s.writeStalwartAPIError(w, err)
		return
	}
	if ref.IsZero() {
		s.writeJSON(w, 404, map[string]any{"error": "not_found"})
		return
	}

	hash, err := hashPasswordSHA512Crypt(req.NewPassword)
	if err != nil {
		log.Printf("[email-glue] hash password error: %v", err)
		s.writeJSON(w, 500, map[string]any{"error": "internal_error"})
		return
	}

	if err := s.stalwart.setPrincipalPassword(ref, hash); err != nil {
		log.Printf("[email-glue] stalwart setPassword error: %v", err)
		s.writeStalwartAPIError(w, err)
		return
	}

	s.writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	s.writeJSON(w, 200, map[string]any{"ok": true})
}

type statusResp struct {
	Stalwart string `json:"stalwart"`
	Ejabberd string `json:"ejabberd"`
}

func stalwartHTTPRoot(apiBase string) string {
	apiBase = strings.TrimSpace(apiBase)
	if apiBase == "" {
		return "http://127.0.0.1:8080"
	}
	u, err := url.Parse(apiBase)
	if err != nil {
		return strings.TrimRight(apiBase, "/")
	}
	u.Path = ""
	u.RawQuery = ""
	u.Fragment = ""
	return strings.TrimRight(u.String(), "/")
}

func httpStatusOK(ctx context.Context, c *http.Client, method, u string, body io.Reader, contentType string) bool {
	req, err := http.NewRequestWithContext(ctx, method, u, body)
	if err != nil {
		return false
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode == 200
}

func (s *server) statusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	now := time.Now()
	code, body := s.status.getOrCompute(r.Context(), now, func(ctx context.Context) (int, []byte) {
		// Tight per-probe timeouts.
		hc := &http.Client{Timeout: 2 * time.Second}

		stalCtx, cancelStal := context.WithTimeout(ctx, 2*time.Second)
		stalRoot := stalwartHTTPRoot(s.cfg.StalwartAPIBase)
		stalOK := httpStatusOK(stalCtx, hc, http.MethodGet, stalRoot+"/healthz/live", nil, "")
		cancelStal()

		ejCtx, cancelEj := context.WithTimeout(ctx, 2*time.Second)
		ejOK := httpStatusOK(ejCtx, hc, http.MethodPost, "http://127.0.0.1:5281/api/status", strings.NewReader("{}"), "application/json")
		cancelEj()

		resp := statusResp{Stalwart: "offline", Ejabberd: "offline"}
		if stalOK {
			resp.Stalwart = "online"
		}
		if ejOK {
			resp.Ejabberd = "online"
		}

		statusCode := 200
		if !stalOK || !ejOK {
			statusCode = 503
		}
		b, err := json.Marshal(resp)
		if err != nil {
			// Very unlikely; fallback to a hardcoded minimal response.
			return 503, []byte(`{"stalwart":"offline","ejabberd":"offline"}`)
		}
		return statusCode, b
	})

	s.writeRawJSON(w, code, body)
}

func setCORSHeaders(w http.ResponseWriter, r *http.Request) {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		return
	}
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", origin)
	h.Add("Vary", "Origin")
	h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	h.Set("Access-Control-Allow-Headers", "Content-Type, X-Client-Token, X-Auth-Token")
	h.Set("Access-Control-Max-Age", "600")
}

func withMiddleware(srv *server, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Security headers (minimal)
		w.Header().Set("Strict-Transport-Security", "max-age=31536000")

		setCORSHeaders(w, r)

		// CORS preflight requests are unauthenticated by design.
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		// Optional public token gate for all endpoints (including /health).
		if srv.cfg.RequireClientToken && !srv.checkClientToken(r) {
			srv.writeJSON(w, 401, map[string]any{"error": "unauthorized"})
			return
		}

		start := time.Now()
		h.ServeHTTP(w, r)
		ip := srv.remoteIP(r)
		log.Printf("[email-glue] %s %s %s in %s", ip, r.Method, r.URL.Path, time.Since(start).Truncate(time.Millisecond))
	})
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("[email-glue] config error: %v", err)
	}

	// Fail fast if TLS files missing.
	if _, err := os.Stat(cfg.CertFile); err != nil {
		log.Fatalf("[email-glue] missing cert file %s: %v", cfg.CertFile, err)
	}
	if _, err := os.Stat(cfg.KeyFile); err != nil {
		log.Fatalf("[email-glue] missing key file %s: %v", cfg.KeyFile, err)
	}

	reloader := &certReloader{certPath: cfg.CertFile, keyPath: cfg.KeyFile}

	tlsCfg := &tls.Config{
		MinVersion:     tls.VersionTLS12,
		GetCertificate: reloader.GetCertificate,
	}

	srv := &server{
		cfg:      cfg,
		stalwart: newStalwartClient(cfg),
		// Default to a public-but-gated profile: token-protected by default,
		// tolerant for normal client traffic, but not effectively unlimited.
		globalRL: newBucketStore(5.0, 30, 30*time.Minute),
		signupRL: newBucketStore(1.0/120.0, 10, 24*time.Hour),
		status:   newStatusCache(30 * time.Second),
	}

	mux := http.NewServeMux()
	// be forgiving with trailing slashes
	mux.HandleFunc("/health", srv.health)
	mux.HandleFunc("/health/", srv.health)
	mux.HandleFunc("/status", srv.statusHandler)
	mux.HandleFunc("/status/", srv.statusHandler)
	mux.HandleFunc("/signup", srv.signup)
	mux.HandleFunc("/signup/", srv.signup)
	mux.HandleFunc("/account", srv.deleteAccount)
	mux.HandleFunc("/account/", srv.deleteAccount)
	mux.HandleFunc("/password", srv.changePassword)
	mux.HandleFunc("/password/", srv.changePassword)

	h := withMiddleware(srv, mux)

	httpSrv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		TLSConfig:         tlsCfg,
	}

	log.Printf("[email-glue] starting on https://%s (domain=%s stalwart=%s defaultQuotaBytes=%d)",
		cfg.ListenAddr, cfg.Domain, cfg.StalwartAPIBase, cfg.DefaultQuotaBytes)

	// Use TLSConfig.GetCertificate, so pass empty paths.
	if err := httpSrv.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("[email-glue] ListenAndServeTLS: %v", err)
	}
}
