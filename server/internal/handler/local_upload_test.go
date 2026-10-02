package handler

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/multica-ai/multica/server/internal/storage"
)

func localUploadTestStorage(t *testing.T) *storage.LocalStorage {
	t.Helper()
	if testHandler == nil {
		t.Skip("test database not available")
	}
	t.Setenv("LOCAL_UPLOAD_DIR", t.TempDir())
	t.Setenv("LOCAL_UPLOAD_BASE_URL", "")
	local := storage.NewLocalStorageFromEnv()
	if local == nil {
		t.Fatal("NewLocalStorageFromEnv returned nil")
	}
	previous := testHandler.Storage
	testHandler.Storage = local
	t.Cleanup(func() { testHandler.Storage = previous })
	return local
}

func putLocalUpload(t *testing.T, local *storage.LocalStorage, key, body string) {
	t.Helper()
	if _, err := local.Upload(context.Background(), key, []byte(body), "text/plain", "fixture.txt"); err != nil {
		t.Fatalf("Upload(%q): %v", key, err)
	}
}

func requestLocalUpload(path, userID string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if userID != "" {
		req.Header.Set("X-User-ID", userID)
	}
	rec := httptest.NewRecorder()
	testHandler.ServeLocalUpload(rec, req)
	return rec
}

func TestLocalUpload_MemberGets200(t *testing.T) {
	local := localUploadTestStorage(t)
	key := "workspaces/" + testWorkspaceID + "/member.txt"
	const body = "member upload bytes"
	putLocalUpload(t, local, key, body)
	rec := requestLocalUpload("/uploads/"+key, testUserID)
	if rec.Code != http.StatusOK || rec.Body.String() != body {
		t.Fatalf("status = %d, body = %q; want 200 and %q", rec.Code, rec.Body.String(), body)
	}
	requireAttachmentPreviewCSP(t, rec.Header())
}

func TestLocalUpload_NonMember404(t *testing.T) {
	local := localUploadTestStorage(t)
	foreignUser := dbfx.User(t, "Upload fixture user", "upload-user-"+uuid.NewString()+"@example.test")
	foreignWorkspace := dbfx.Workspace(t, "Upload fixture workspace", "upload-ws-"+uuid.NewString())
	dbfx.Member(t, foreignWorkspace, foreignUser, "owner")
	key := "workspaces/" + foreignWorkspace + "/private.txt"
	const body = "foreign workspace secret bytes"
	putLocalUpload(t, local, key, body)
	rec := requestLocalUpload("/uploads/"+key, testUserID)
	if rec.Code != http.StatusNotFound || strings.Contains(rec.Body.String(), body) {
		t.Fatalf("status = %d, body = %q; want 404 without file bytes", rec.Code, rec.Body.String())
	}
}

func TestLocalUpload_DotDotCrossWorkspace404(t *testing.T) {
	local := localUploadTestStorage(t)
	foreignUser := dbfx.User(t, "Upload fixture user", "upload-user-"+uuid.NewString()+"@example.test")
	foreignWorkspace := dbfx.Workspace(t, "Upload fixture workspace", "upload-ws-"+uuid.NewString())
	dbfx.Member(t, foreignWorkspace, foreignUser, "owner")
	key := "workspaces/" + foreignWorkspace + "/private.pdf"
	const body = "foreign workspace file bytes"
	if _, err := local.Upload(context.Background(), key, []byte(body), "application/pdf", "secret-LOI.pdf"); err != nil {
		t.Fatal(err)
	}
	paths := map[string]string{
		"plain":   "/uploads/workspaces/" + testWorkspaceID + "/../" + foreignWorkspace + "/private.pdf",
		"encoded": "/uploads/workspaces/" + testWorkspaceID + "/%2e%2e/" + foreignWorkspace + "/private.pdf",
		"users":   "/uploads/users/" + testUserID + "/../../" + key,
	}
	for name, target := range paths {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, target, nil)
			if name == "encoded" && !strings.Contains(req.URL.Path, "/../") {
				t.Fatalf("encoded target did not decode to dot-dot: %q", req.URL.Path)
			}
			req.Header.Set("X-User-ID", testUserID)
			rec := httptest.NewRecorder()
			testHandler.ServeLocalUpload(rec, req)
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404; body=%q", rec.Code, rec.Body.String())
			}
			if got := rec.Header().Get("Content-Disposition"); got != "" {
				t.Fatalf("Content-Disposition = %q, want empty", got)
			}
			if strings.Contains(rec.Body.String(), body) || strings.Contains(rec.Body.String(), "secret-LOI") {
				t.Fatalf("response leaked foreign upload: %q", rec.Body.String())
			}
		})
	}
}

func TestLocalUpload_UserPrefixAnyAuthenticated200(t *testing.T) {
	local := localUploadTestStorage(t)
	otherUser := dbfx.User(t, "Avatar fixture user", "avatar-user-"+uuid.NewString()+"@example.test")
	key := "users/" + otherUser + "/avatar.png"
	const body = "avatar bytes"
	putLocalUpload(t, local, key, body)
	rec := requestLocalUpload("/uploads/"+key, testUserID)
	if rec.Code != http.StatusOK || rec.Body.String() != body {
		t.Fatalf("status = %d, body = %q; want 200 and %q", rec.Code, rec.Body.String(), body)
	}
}

func TestLocalUpload_UnknownPrefix404(t *testing.T) {
	local := localUploadTestStorage(t)
	key := "other/private.txt"
	const body = "unknown prefix secret"
	putLocalUpload(t, local, key, body)
	rec := requestLocalUpload("/uploads/"+key, testUserID)
	if rec.Code != http.StatusNotFound || strings.Contains(rec.Body.String(), body) {
		t.Fatalf("status = %d, body = %q; want 404 without file bytes", rec.Code, rec.Body.String())
	}
}

func TestLocalUpload_DirectoryShapes404(t *testing.T) {
	local := localUploadTestStorage(t)
	putLocalUpload(t, local, "workspaces/"+testWorkspaceID+"/private.txt", "private file bytes")
	for _, key := range []string{
		"", "workspaces/", "workspaces/" + testWorkspaceID,
		"workspaces/" + testWorkspaceID + "/", "users/", "users/" + testUserID + "/",
	} {
		t.Run("/uploads/"+key, func(t *testing.T) {
			rec := requestLocalUpload("/uploads/"+key, testUserID)
			if rec.Code != http.StatusNotFound || strings.Contains(rec.Body.String(), "private.txt") {
				t.Fatalf("status = %d, body = %q; want 404 without listing", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestLocalUpload_NoUser401(t *testing.T) {
	local := localUploadTestStorage(t)
	key := "workspaces/" + testWorkspaceID + "/private.txt"
	const body = "no user secret"
	putLocalUpload(t, local, key, body)
	rec := requestLocalUpload("/uploads/"+key, "")
	if rec.Code != http.StatusUnauthorized || strings.Contains(rec.Body.String(), body) {
		t.Fatalf("status = %d, body = %q; want 401 without file bytes", rec.Code, rec.Body.String())
	}
}
