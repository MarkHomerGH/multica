package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/multica-ai/multica/server/internal/analytics"
	"github.com/multica-ai/multica/server/internal/auth"
	"github.com/multica-ai/multica/server/internal/events"
	"github.com/multica-ai/multica/server/internal/realtime"
	"github.com/multica-ai/multica/server/internal/storage"
	dbfx "github.com/multica-ai/multica/server/internal/testutil"
)

func uploadsTestRouter(t *testing.T) (http.Handler, string, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("S3_BUCKET", "")
	t.Setenv("LOCAL_UPLOAD_DIR", dir)
	t.Setenv("LOCAL_UPLOAD_BASE_URL", "")
	key := "workspaces/" + testWorkspaceID + "/router-private.txt"
	full := filepath.Join(dir, filepath.FromSlash(key))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	const body = "router upload private bytes"
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	router := NewRouter(testPool, realtime.NewHub(), events.New(), analytics.NoopClient{}, nil)
	return router, "/uploads/" + key, body
}

func TestUploadsRoute_AnonymousRejected(t *testing.T) {
	router, path, body := uploadsTestRouter(t)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	if rec.Code != http.StatusUnauthorized || strings.Contains(rec.Body.String(), body) {
		t.Fatalf("status = %d, body = %q; want 401 without file bytes", rec.Code, rec.Body.String())
	}
	// An untrusted client header must not stand in for a login. This also
	// proves the router runs Auth before the handler's membership check.
	forged := httptest.NewRequest(http.MethodGet, path, nil)
	forged.Header.Set("X-User-ID", testUserID)
	forgedRec := httptest.NewRecorder()
	router.ServeHTTP(forgedRec, forged)
	if forgedRec.Code != http.StatusUnauthorized || strings.Contains(forgedRec.Body.String(), body) {
		t.Fatalf("forged header: status = %d, body = %q; want 401 without file bytes", forgedRec.Code, forgedRec.Body.String())
	}
	for _, directory := range []string{"/uploads/", "/uploads/workspaces/"} {
		t.Run(directory, func(t *testing.T) {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, directory, nil))
			if rec.Code == http.StatusOK {
				t.Fatalf("anonymous directory request %q returned 200: %q", directory, rec.Body.String())
			}
		})
	}
}

func TestUploadsRoute_CookieMemberAllowed(t *testing.T) {
	router, path, body := uploadsTestRouter(t)
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.AddCookie(&http.Cookie{Name: auth.AuthCookieName, Value: testToken})
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Body.String() != body {
		t.Fatalf("status = %d, body = %q; want 200 and %q", rec.Code, rec.Body.String(), body)
	}
}

func TestUploadsRoute_DotDotRejected(t *testing.T) {
	router, _, _ := uploadsTestRouter(t)
	fx := dbfx.New(testPool, testWorkspaceID, testUserID)
	foreignUser := fx.User(t, "Upload fixture user", "upload-user-"+uuid.NewString()+"@example.test")
	foreignWorkspace := fx.Workspace(t, "Upload fixture workspace", "upload-ws-"+uuid.NewString())
	fx.Member(t, foreignWorkspace, foreignUser, "owner")
	local := storage.NewLocalStorageFromEnv()
	if local == nil {
		t.Fatal("NewLocalStorageFromEnv returned nil")
	}
	key := "workspaces/" + foreignWorkspace + "/private.pdf"
	const body = "foreign router upload bytes"
	if _, err := local.Upload(context.Background(), key, []byte(body), "application/pdf", "secret-LOI.pdf"); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/uploads/workspaces/"+testWorkspaceID+"/%2e%2e/"+foreignWorkspace+"/private.pdf", nil)
	if !strings.Contains(req.URL.Path, "/../") {
		t.Fatalf("encoded target did not decode to dot-dot: %q", req.URL.Path)
	}
	req.AddCookie(&http.Cookie{Name: auth.AuthCookieName, Value: testToken})
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatalf("status = 200, want rejected request; body=%q", rec.Body.String())
	}
	if got := rec.Header().Get("Content-Disposition"); got != "" {
		t.Fatalf("Content-Disposition = %q, want empty", got)
	}
	if strings.Contains(rec.Body.String(), body) {
		t.Fatalf("response leaked foreign file bytes: %q", rec.Body.String())
	}
}
