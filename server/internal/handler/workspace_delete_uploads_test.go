package handler

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/multica-ai/multica/server/internal/testutil"
)

type workspaceUploadRecordingStorage struct {
	mockStorage
	deleted       []string
	deleteCalls   int
	deleteBatches int
}

func (s *workspaceUploadRecordingStorage) KeyFromURL(raw string) string {
	if _, key, ok := strings.Cut(raw, "/uploads/"); ok {
		return key
	}
	return s.mockStorage.KeyFromURL(raw)
}

func (s *workspaceUploadRecordingStorage) Delete(_ context.Context, key string) {
	s.deleteCalls++
	s.deleted = append(s.deleted, key)
}

func (s *workspaceUploadRecordingStorage) DeleteKeys(_ context.Context, keys []string) {
	s.deleteBatches++
	s.deleted = append(s.deleted, keys...)
}

func workspaceUploadTestStorage(t *testing.T) *workspaceUploadRecordingStorage {
	t.Helper()
	store := &workspaceUploadRecordingStorage{}
	previous := testHandler.Storage
	testHandler.Storage = store
	t.Cleanup(func() { testHandler.Storage = previous })
	return store
}

func workspaceUploadTestWorkspace(t *testing.T, slug string) string {
	t.Helper()
	wsID := dbfx.Insert(t, "workspace", testutil.Cols{
		"name": "Workspace upload deletion fixture", "slug": slug,
	})
	dbfx.Insert(t, "member", testutil.Cols{
		"workspace_id": wsID, "user_id": testUserID, "role": "owner",
	})
	return wsID
}

func workspaceUploadTestAgent(t *testing.T, wsID, avatarURL string) string {
	t.Helper()
	runtimeID := dbfx.Insert(t, "agent_runtime", testutil.Cols{
		"workspace_id": wsID, "name": "Upload deletion runtime",
		"runtime_mode": "cloud", "provider": "delete-test", "status": "offline",
		"device_info": "", "metadata": testutil.Raw("'{}'::jsonb"), "owner_id": testUserID,
	})
	return dbfx.Insert(t, "agent", testutil.Cols{
		"workspace_id": wsID, "name": "Upload deletion agent", "avatar_url": avatarURL,
		"runtime_mode": "cloud", "runtime_config": testutil.Raw("'{}'::jsonb"),
		"runtime_id": runtimeID, "owner_id": testUserID,
	})
}

func deleteWorkspaceForUploadTest(t *testing.T, wsID string, wantStatus int) {
	t.Helper()
	req := withURLParam(newRequest(http.MethodDelete, "/api/workspaces/"+wsID, nil), "id", wsID)
	testutil.Call(t, testHandler.DeleteWorkspace, req).Want(wantStatus)
}

func assertWorkspaceUploadDeletes(t *testing.T, store *workspaceUploadRecordingStorage, want []string) {
	t.Helper()
	got := slices.Clone(store.deleted)
	want = slices.Clone(want)
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("deleted storage keys = %v, want %v", got, want)
	}
	if store.deleteCalls != 0 {
		t.Fatalf("individual Delete calls = %d, want 0", store.deleteCalls)
	}
	if len(want) > 0 && store.deleteBatches != 1 {
		t.Fatalf("DeleteKeys calls = %d, want 1", store.deleteBatches)
	}
	if len(want) == 0 && store.deleteBatches != 0 {
		t.Fatalf("DeleteKeys calls = %d, want 0", store.deleteBatches)
	}
}

func TestDeleteWorkspace_DeletesAttachmentFiles(t *testing.T) {
	if testHandler == nil || testPool == nil {
		t.Skip("database not available")
	}
	lockRollupSingleton(t)
	store := workspaceUploadTestStorage(t)
	wsID := workspaceUploadTestWorkspace(t, "handler-tests-delete-upload-attachments")
	issueID := dbfx.Issue(t, "Upload deletion issue", testutil.Cols{"workspace_id": wsID})
	commentID := dbfx.Comment(t, issueID, "Upload deletion comment", testutil.Cols{"workspace_id": wsID})
	issueKey := "workspaces/" + wsID + "/" + uuid.NewString() + ".png"
	commentKey := "workspaces/" + wsID + "/" + uuid.NewString() + ".png"
	for _, att := range []struct {
		key       string
		commentID any
	}{
		{key: issueKey},
		{key: commentKey, commentID: commentID},
	} {
		dbfx.Insert(t, "attachment", testutil.Cols{
			"workspace_id": wsID, "issue_id": issueID, "comment_id": att.commentID,
			"uploader_type": "member", "uploader_id": testUserID,
			"filename": "file.png", "url": "/uploads/" + att.key,
			"content_type": "image/png", "size_bytes": 1,
		})
	}

	deleteWorkspaceForUploadTest(t, wsID, http.StatusNoContent)
	assertWorkspaceUploadDeletes(t, store, []string{issueKey, commentKey})
}

func TestDeleteWorkspace_DeletesWorkspaceAgentSquadAvatars(t *testing.T) {
	if testHandler == nil || testPool == nil {
		t.Skip("database not available")
	}
	lockRollupSingleton(t)
	store := workspaceUploadTestStorage(t)
	wsID := workspaceUploadTestWorkspace(t, "handler-tests-delete-upload-avatars")
	workspaceKey := "workspaces/" + wsID + "/workspace.png"
	agentKey := "workspaces/" + wsID + "/agent.png"
	squadKey := "workspaces/" + wsID + "/squad.png"
	dbfx.Exec(t, `UPDATE workspace SET avatar_url = $1 WHERE id = $2`, avatarURLPath(workspaceKey), wsID)
	agentID := workspaceUploadTestAgent(t, wsID, "/uploads/"+agentKey)
	dbfx.Insert(t, "squad", testutil.Cols{
		"workspace_id": wsID, "name": "Upload deletion squad", "leader_id": agentID,
		"creator_id": testUserID, "avatar_url": avatarURLPath(squadKey),
	})

	deleteWorkspaceForUploadTest(t, wsID, http.StatusNoContent)
	assertWorkspaceUploadDeletes(t, store, []string{workspaceKey, agentKey, squadKey})
}

func TestDeleteWorkspace_KeepsForeignKeys(t *testing.T) {
	if testHandler == nil || testPool == nil {
		t.Skip("database not available")
	}
	lockRollupSingleton(t)
	store := workspaceUploadTestStorage(t)
	wsID := workspaceUploadTestWorkspace(t, "handler-tests-delete-upload-foreign")
	otherID := dbfx.Insert(t, "workspace", testutil.Cols{
		"name": "Other workspace", "slug": "handler-tests-delete-upload-other",
	})
	otherIssueID := dbfx.Issue(t, "Other workspace issue", testutil.Cols{"workspace_id": otherID})
	dbfx.Exec(t, `UPDATE workspace SET avatar_url = $1 WHERE id = $2`,
		avatarURLPath("users/"+testUserID+"/x.png"), wsID)
	agentID := workspaceUploadTestAgent(t, wsID, "/uploads/workspaces/"+otherID+"/x.png")
	dbfx.Insert(t, "squad", testutil.Cols{
		"workspace_id": wsID, "name": "Foreign avatar squad", "leader_id": agentID,
		"creator_id": testUserID, "avatar_url": "https://example.test/a.png",
	})

	deleteWorkspaceForUploadTest(t, wsID, http.StatusNoContent)
	assertWorkspaceUploadDeletes(t, store, nil)
	if n := dbfx.Count(t, `SELECT count(*) FROM workspace WHERE id = $1`, otherID); n != 1 {
		t.Fatalf("other workspace rows = %d, want 1", n)
	}
	if n := dbfx.Count(t, `SELECT count(*) FROM issue WHERE id = $1`, otherIssueID); n != 1 {
		t.Fatalf("other workspace issue rows = %d, want 1", n)
	}
}

func TestDeleteWorkspace_NoFileDeletesWhenDeleteFails(t *testing.T) {
	if testHandler == nil || testPool == nil {
		t.Skip("database not available")
	}
	lockRollupSingleton(t)
	setWorkspaceDeleteLockTimeoutForTest(t, 100*time.Millisecond)
	store := workspaceUploadTestStorage(t)
	wsID := workspaceUploadTestWorkspace(t, "handler-tests-delete-upload-failure")
	issueID := dbfx.Issue(t, "Failed upload deletion", testutil.Cols{"workspace_id": wsID})
	attachmentID := dbfx.Insert(t, "attachment", testutil.Cols{
		"workspace_id": wsID, "issue_id": issueID,
		"uploader_type": "member", "uploader_id": testUserID,
		"filename": "file.png", "url": "/uploads/workspaces/" + wsID + "/" + uuid.NewString() + ".png",
		"content_type": "image/png", "size_bytes": 1,
	})

	holder, err := testPool.Acquire(context.Background())
	if err != nil {
		t.Fatalf("acquire rollup lock holder: %v", err)
	}
	if _, err := holder.Exec(context.Background(), `SELECT pg_advisory_lock(4246)`); err != nil {
		holder.Release()
		t.Fatalf("hold rollup lock: %v", err)
	}
	t.Cleanup(func() {
		_, _ = holder.Exec(context.Background(), `SELECT pg_advisory_unlock(4246)`)
		holder.Release()
	})

	deleteWorkspaceForUploadTest(t, wsID, http.StatusServiceUnavailable)
	assertWorkspaceUploadDeletes(t, store, nil)
	if n := dbfx.Count(t, `SELECT count(*) FROM attachment WHERE id = $1`, attachmentID); n != 1 {
		t.Fatalf("attachment rows after failed delete = %d, want 1", n)
	}
}
