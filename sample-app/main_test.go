package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	rec := httptest.NewRecorder()
	newMux("test-host").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /healthz returned %d, want 200", rec.Code)
	}
}

func TestRootReportsVersionAndHost(t *testing.T) {
	version = "1.2.3"
	rec := httptest.NewRecorder()
	newMux("test-host").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET / returned %d, want 200", rec.Code)
	}
	var got info
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatalf("GET / did not return JSON: %v", err)
	}
	if got.Version != "1.2.3" || got.Hostname != "test-host" || got.App != "sample-app" {
		t.Fatalf("unexpected body: %+v", got)
	}
}

func TestUnknownPathIs404(t *testing.T) {
	rec := httptest.NewRecorder()
	newMux("test-host").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /nope returned %d, want 404", rec.Code)
	}
}
