package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	opensearch "github.com/opensearch-project/opensearch-go/v4"
	"github.com/redis/go-redis/v9"
)

const (
	// Local fogstack defaults. Override every value with env vars outside the demo.
	defaultAddr            = ":8080"
	defaultDatabaseURL     = "postgres://fogstack:test@fogstack-postgres:5432/appdb?sslmode=disable"
	defaultRedisAddr       = "fogstack-redis:6379"
	defaultAWSEndpoint     = "http://aws-api:4566"
	defaultAWSRegion       = "us-east-1"
	defaultAWSAccessKeyID  = "test"
	defaultAWSSecretAccess = "test"
	defaultS3Bucket        = "full-tour-notes"
	defaultOpenSearchURL   = "http://opensearch:9200"
	defaultOpenSearchIndex = "full-tour-notes"
	maxRequestBytes        = 1 << 20
)

type appConfig struct {
	Addr               string
	DatabaseURL        string
	RedisURL           string
	RedisAddr          string
	RedisPassword      string
	RedisDB            int
	AWSRegion          string
	AWSEndpointURL     string
	AWSAccessKeyID     string
	AWSSecretAccessKey string
	S3Bucket           string
	OpenSearchURL      string
	OpenSearchIndex    string
	CacheTTL           time.Duration
	PresignTTL         time.Duration
	BackendCallTimeout time.Duration
}

type application struct {
	cfg       appConfig
	db        *pgxpool.Pool
	redis     *redis.Client
	s3        *s3.Client
	presigner *s3.PresignClient
	search    *opensearch.Client
	log       *slog.Logger

	ensureMu sync.Mutex
	ensured  bool
}

type note struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	ObjectKey string    `json:"object_key"`
}

type noteResponse struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	ObjectKey string    `json:"object_key"`
	ObjectRef string    `json:"object_ref"`
	ObjectURL string    `json:"object_url,omitempty"`
	CacheHit  bool      `json:"cache_hit"`
}

type createNoteRequest struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

type checkResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func main() {
	ctx := context.Background()
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg := loadConfig()
	app, err := newApplication(ctx, cfg, logger)
	if err != nil {
		logger.Error("initialize application", "error", err)
		os.Exit(1)
	}
	defer app.close()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", app.handleIndex)
	mux.HandleFunc("GET /healthz", app.handleHealth)
	mux.HandleFunc("POST /notes", app.handleCreateNote)
	mux.HandleFunc("GET /notes", app.handleListNotes)

	server := &http.Server{
		Addr:              cfg.Addr,
		Handler:           recoverer(logger, requestLogger(logger, mux)),
		ReadHeaderTimeout: 5 * time.Second,
	}

	logger.Info("starting full-tour notes service", "addr", cfg.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("http server stopped", "error", err)
		os.Exit(1)
	}
}

func loadConfig() appConfig {
	return appConfig{
		Addr:               listenAddr(),
		DatabaseURL:        firstEnv(defaultDatabaseURL, "DATABASE_URL", "POSTGRES_URL"),
		RedisURL:           os.Getenv("REDIS_URL"),
		RedisAddr:          getenv("REDIS_ADDR", defaultRedisAddr),
		RedisPassword:      os.Getenv("REDIS_PASSWORD"),
		RedisDB:            getenvInt("REDIS_DB", 0),
		AWSRegion:          firstEnv(defaultAWSRegion, "AWS_REGION", "AWS_DEFAULT_REGION"),
		AWSEndpointURL:     getenv("AWS_ENDPOINT_URL", defaultAWSEndpoint),
		AWSAccessKeyID:     getenv("AWS_ACCESS_KEY_ID", defaultAWSAccessKeyID),
		AWSSecretAccessKey: getenv("AWS_SECRET_ACCESS_KEY", defaultAWSSecretAccess),
		S3Bucket:           getenv("S3_BUCKET", defaultS3Bucket),
		OpenSearchURL:      getenv("OPENSEARCH_URL", defaultOpenSearchURL),
		OpenSearchIndex:    getenv("OPENSEARCH_INDEX", defaultOpenSearchIndex),
		CacheTTL:           getenvDuration("CACHE_TTL", 10*time.Minute),
		PresignTTL:         getenvDuration("S3_PRESIGN_TTL", 15*time.Minute),
		BackendCallTimeout: getenvDuration("BACKEND_CALL_TIMEOUT", 5*time.Second),
	}
}

func listenAddr() string {
	if value := strings.TrimSpace(os.Getenv("ADDR")); value != "" {
		return value
	}
	port := strings.TrimSpace(os.Getenv("HTTP_PORT"))
	if port == "" {
		return defaultAddr
	}
	if strings.Contains(port, ":") {
		return port
	}
	return ":" + port
}

func newApplication(ctx context.Context, cfg appConfig, logger *slog.Logger) (*application, error) {
	db, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("configure postgres: %w", err)
	}

	redisOptions := &redis.Options{
		Addr:     cfg.RedisAddr,
		Password: cfg.RedisPassword,
		DB:       cfg.RedisDB,
	}
	if cfg.RedisURL != "" {
		redisOptions, err = redis.ParseURL(cfg.RedisURL)
		if err != nil {
			db.Close()
			return nil, fmt.Errorf("parse redis url: %w", err)
		}
	}
	redisClient := redis.NewClient(redisOptions)

	awsCfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(cfg.AWSRegion),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			cfg.AWSAccessKeyID,
			cfg.AWSSecretAccessKey,
			"",
		)),
	)
	if err != nil {
		db.Close()
		redisClient.Close()
		return nil, fmt.Errorf("configure aws sdk: %w", err)
	}
	s3Client := s3.NewFromConfig(awsCfg, func(options *s3.Options) {
		options.BaseEndpoint = aws.String(cfg.AWSEndpointURL)
		options.UsePathStyle = true
	})

	searchClient, err := opensearch.NewClient(opensearch.Config{
		Addresses: []string{cfg.OpenSearchURL},
	})
	if err != nil {
		db.Close()
		redisClient.Close()
		return nil, fmt.Errorf("configure opensearch: %w", err)
	}

	return &application{
		cfg:       cfg,
		db:        db,
		redis:     redisClient,
		s3:        s3Client,
		presigner: s3.NewPresignClient(s3Client),
		search:    searchClient,
		log:       logger,
	}, nil
}

func (a *application) close() {
	a.db.Close()
	if err := a.redis.Close(); err != nil {
		a.log.Warn("close redis client", "error", err)
	}
}

func (a *application) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = io.WriteString(w, `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>full-tour notes</title></head>
<body>
<h1>full-tour notes</h1>
<form method="post" action="/notes">
<input name="title" placeholder="Title">
<br>
<textarea name="body" placeholder="Note"></textarea>
<br>
<button type="submit">Create note</button>
</form>
<p><a href="/healthz">healthz</a> <a href="/notes">notes json</a></p>
</body>
</html>`)
}

func (a *application) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), a.cfg.BackendCallTimeout)
	defer cancel()

	checks := map[string]checkResult{
		"postgres":   a.checkPostgres(ctx),
		"redis":      a.checkRedis(ctx),
		"s3":         a.checkS3(ctx),
		"opensearch": a.checkOpenSearch(ctx),
	}

	ok := true
	for _, check := range checks {
		if !check.OK {
			ok = false
			break
		}
	}

	status := http.StatusOK
	if !ok {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]any{
		"ok":     ok,
		"checks": checks,
	})
}

func (a *application) handleCreateNote(w http.ResponseWriter, r *http.Request) {
	var input createNoteRequest
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		if err := decodeJSON(w, r, &input); err != nil {
			writeError(w, http.StatusBadRequest, err)
			return
		}
	} else {
		if err := r.ParseForm(); err != nil {
			writeError(w, http.StatusBadRequest, fmt.Errorf("parse form: %w", err))
			return
		}
		input.Title = r.FormValue("title")
		input.Body = r.FormValue("body")
	}

	input.Title = strings.TrimSpace(input.Title)
	input.Body = strings.TrimSpace(input.Body)
	if input.Title == "" {
		writeError(w, http.StatusBadRequest, errors.New("title is required"))
		return
	}
	if input.Body == "" {
		writeError(w, http.StatusBadRequest, errors.New("body is required"))
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), a.cfg.BackendCallTimeout)
	defer cancel()
	if err := a.ensureStorage(ctx); err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}

	created := note{
		ID:        randomID(),
		CreatedAt: time.Now().UTC(),
		Title:     input.Title,
		Body:      input.Body,
	}
	created.ObjectKey = "notes/" + created.ID + ".json"

	if err := a.insertNote(ctx, created); err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}
	if err := a.putNoteObject(ctx, created); err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}
	if err := a.indexNote(ctx, created); err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}
	if err := a.cacheNote(ctx, created); err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"note": a.toResponse(r.Context(), created, false),
	})
}

func (a *application) handleListNotes(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), a.cfg.BackendCallTimeout)
	defer cancel()
	if err := a.ensureStorage(ctx); err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}

	limit := parseLimit(r.URL.Query().Get("limit"), 20, 100)
	query := strings.TrimSpace(r.URL.Query().Get("q"))

	var (
		notes     []note
		cacheHits map[string]bool
		err       error
	)
	if query != "" {
		notes, cacheHits, err = a.searchNotes(ctx, query, limit)
	} else {
		notes, cacheHits, err = a.listNotes(ctx, limit)
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, err)
		return
	}

	items := make([]noteResponse, 0, len(notes))
	for _, n := range notes {
		items = append(items, a.toResponse(r.Context(), n, cacheHits[n.ID]))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"count": len(items),
		"q":     query,
		"notes": items,
	})
}

func (a *application) ensureStorage(ctx context.Context) error {
	a.ensureMu.Lock()
	defer a.ensureMu.Unlock()
	if a.ensured {
		return nil
	}

	if err := a.ensurePostgres(ctx); err != nil {
		return err
	}
	if err := a.ensureBucket(ctx); err != nil {
		return err
	}
	if err := a.ensureOpenSearchIndex(ctx); err != nil {
		return err
	}

	a.ensured = true
	return nil
}

func (a *application) ensurePostgres(ctx context.Context) error {
	_, err := a.db.Exec(ctx, `
CREATE TABLE IF NOT EXISTS notes (
	id text PRIMARY KEY,
	created_at timestamptz NOT NULL,
	title text NOT NULL,
	body text NOT NULL,
	object_key text NOT NULL
)`)
	if err != nil {
		return fmt.Errorf("ensure postgres schema: %w", err)
	}
	return nil
}

func (a *application) ensureBucket(ctx context.Context) error {
	_, err := a.s3.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(a.cfg.S3Bucket)})
	if err == nil {
		return nil
	}
	_, err = a.s3.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(a.cfg.S3Bucket)})
	if err != nil {
		return fmt.Errorf("ensure s3 bucket %q: %w", a.cfg.S3Bucket, err)
	}
	return nil
}

func (a *application) ensureOpenSearchIndex(ctx context.Context) error {
	body := strings.NewReader(`{
  "mappings": {
    "properties": {
      "id": {"type": "keyword"},
      "created_at": {"type": "date"},
      "title": {"type": "text"},
      "body": {"type": "text"},
      "object_key": {"type": "keyword"}
    }
  }
}`)
	resp, err := a.openSearchRequest(ctx, http.MethodPut, "/"+url.PathEscape(a.cfg.OpenSearchIndex), body)
	if err != nil {
		return fmt.Errorf("ensure opensearch index: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusCreated {
		return nil
	}
	var payload map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&payload)
	if resp.StatusCode == http.StatusBadRequest && strings.Contains(fmt.Sprint(payload), "resource_already_exists_exception") {
		return nil
	}
	return fmt.Errorf("ensure opensearch index: status %d %s", resp.StatusCode, payload)
}

func (a *application) checkPostgres(ctx context.Context) checkResult {
	if err := a.db.Ping(ctx); err != nil {
		return checkResult{OK: false, Error: err.Error()}
	}
	return checkResult{OK: true}
}

func (a *application) checkRedis(ctx context.Context) checkResult {
	if err := a.redis.Ping(ctx).Err(); err != nil {
		return checkResult{OK: false, Error: err.Error()}
	}
	return checkResult{OK: true}
}

func (a *application) checkS3(ctx context.Context) checkResult {
	if _, err := a.s3.ListBuckets(ctx, &s3.ListBucketsInput{}); err != nil {
		return checkResult{OK: false, Error: err.Error()}
	}
	return checkResult{OK: true}
}

func (a *application) checkOpenSearch(ctx context.Context) checkResult {
	resp, err := a.openSearchRequest(ctx, http.MethodGet, "/", nil)
	if err != nil {
		return checkResult{OK: false, Error: err.Error()}
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return checkResult{OK: false, Error: fmt.Sprintf("status %d", resp.StatusCode)}
	}
	return checkResult{OK: true}
}

func (a *application) insertNote(ctx context.Context, n note) error {
	_, err := a.db.Exec(ctx,
		`INSERT INTO notes (id, created_at, title, body, object_key) VALUES ($1, $2, $3, $4, $5)`,
		n.ID, n.CreatedAt, n.Title, n.Body, n.ObjectKey,
	)
	if err != nil {
		return fmt.Errorf("insert postgres note: %w", err)
	}
	return nil
}

func (a *application) putNoteObject(ctx context.Context, n note) error {
	payload, err := json.Marshal(n)
	if err != nil {
		return fmt.Errorf("encode note object: %w", err)
	}
	_, err = a.s3.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(a.cfg.S3Bucket),
		Key:         aws.String(n.ObjectKey),
		Body:        bytes.NewReader(payload),
		ContentType: aws.String("application/json"),
	})
	if err != nil {
		return fmt.Errorf("put s3 object: %w", err)
	}
	return nil
}

func (a *application) indexNote(ctx context.Context, n note) error {
	payload, err := json.Marshal(n)
	if err != nil {
		return fmt.Errorf("encode opensearch document: %w", err)
	}
	path := "/" + url.PathEscape(a.cfg.OpenSearchIndex) + "/_doc/" + url.PathEscape(n.ID) + "?refresh=true"
	resp, err := a.openSearchRequest(ctx, http.MethodPut, path, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("index opensearch document: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("index opensearch document: status %d", resp.StatusCode)
	}
	return nil
}

func (a *application) cacheNote(ctx context.Context, n note) error {
	payload, err := json.Marshal(n)
	if err != nil {
		return fmt.Errorf("encode redis note: %w", err)
	}
	if err := a.redis.Set(ctx, cacheKey(n.ID), payload, a.cfg.CacheTTL).Err(); err != nil {
		return fmt.Errorf("cache redis note: %w", err)
	}
	return nil
}

func (a *application) listNotes(ctx context.Context, limit int) ([]note, map[string]bool, error) {
	rows, err := a.db.Query(ctx, `SELECT id FROM notes ORDER BY created_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, nil, fmt.Errorf("list postgres note ids: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, nil, fmt.Errorf("scan note id: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("iterate note ids: %w", err)
	}

	return a.notesByID(ctx, ids)
}

func (a *application) searchNotes(ctx context.Context, query string, limit int) ([]note, map[string]bool, error) {
	payload, err := json.Marshal(map[string]any{
		"size": limit,
		"query": map[string]any{
			"multi_match": map[string]any{
				"query":  query,
				"fields": []string{"title^2", "body"},
			},
		},
		"sort": []any{
			map[string]any{"created_at": map[string]string{"order": "desc"}},
		},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("encode opensearch query: %w", err)
	}
	path := "/" + url.PathEscape(a.cfg.OpenSearchIndex) + "/_search"
	resp, err := a.openSearchRequest(ctx, http.MethodGet, path, bytes.NewReader(payload))
	if err != nil {
		return nil, nil, fmt.Errorf("search opensearch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, nil, fmt.Errorf("search opensearch: status %d", resp.StatusCode)
	}

	var result struct {
		Hits struct {
			Hits []struct {
				ID string `json:"_id"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, nil, fmt.Errorf("decode opensearch results: %w", err)
	}

	ids := make([]string, 0, len(result.Hits.Hits))
	for _, hit := range result.Hits.Hits {
		if hit.ID != "" {
			ids = append(ids, hit.ID)
		}
	}
	return a.notesByID(ctx, ids)
}

func (a *application) notesByID(ctx context.Context, ids []string) ([]note, map[string]bool, error) {
	notes := make([]note, 0, len(ids))
	cacheHits := make(map[string]bool, len(ids))
	for _, id := range ids {
		n, cacheHit, err := a.noteByID(ctx, id)
		if errors.Is(err, pgx.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, nil, err
		}
		notes = append(notes, n)
		cacheHits[n.ID] = cacheHit
	}
	return notes, cacheHits, nil
}

func (a *application) noteByID(ctx context.Context, id string) (note, bool, error) {
	cached, err := a.redis.Get(ctx, cacheKey(id)).Bytes()
	if err == nil {
		var n note
		if err := json.Unmarshal(cached, &n); err == nil {
			return n, true, nil
		}
	}

	var n note
	err = a.db.QueryRow(ctx,
		`SELECT id, created_at, title, body, object_key FROM notes WHERE id = $1`,
		id,
	).Scan(&n.ID, &n.CreatedAt, &n.Title, &n.Body, &n.ObjectKey)
	if err != nil {
		return note{}, false, fmt.Errorf("get postgres note %q: %w", id, err)
	}
	if err := a.cacheNote(ctx, n); err != nil {
		a.log.Warn("refresh redis cache", "note_id", n.ID, "error", err)
	}
	return n, false, nil
}

func (a *application) toResponse(ctx context.Context, n note, cacheHit bool) noteResponse {
	objectRef := "s3://" + a.cfg.S3Bucket + "/" + n.ObjectKey
	resp := noteResponse{
		ID:        n.ID,
		CreatedAt: n.CreatedAt,
		Title:     n.Title,
		Body:      n.Body,
		ObjectKey: n.ObjectKey,
		ObjectRef: objectRef,
		CacheHit:  cacheHit,
	}

	presignCtx, cancel := context.WithTimeout(ctx, a.cfg.BackendCallTimeout)
	defer cancel()
	req, err := a.presigner.PresignGetObject(presignCtx, &s3.GetObjectInput{
		Bucket: aws.String(a.cfg.S3Bucket),
		Key:    aws.String(n.ObjectKey),
	}, s3.WithPresignExpires(a.cfg.PresignTTL))
	if err == nil {
		resp.ObjectURL = req.URL
	}
	return resp
}

func (a *application) openSearchRequest(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, path, body)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return a.search.Transport.Perform(req)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, target any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("decode json: %w", err)
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("request body must contain a single json object")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Default().Warn("write json response", "error", err)
	}
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]any{
		"ok":    false,
		"error": err.Error(),
	})
}

func requestLogger(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logger.Info("request", "method", r.Method, "path", r.URL.Path, "duration", time.Since(start))
	})
}

func recoverer(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if value := recover(); value != nil {
				logger.Error("panic recovered", "panic", value)
				writeError(w, http.StatusInternalServerError, errors.New("internal server error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func parseLimit(value string, fallback, max int) int {
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 1 {
		return fallback
	}
	if parsed > max {
		return max
	}
	return parsed
}

func cacheKey(id string) string {
	return "full-tour:note:" + id
}

func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

func getenv(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func firstEnv(fallback string, keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
		}
	}
	return fallback
}

func getenvInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}
