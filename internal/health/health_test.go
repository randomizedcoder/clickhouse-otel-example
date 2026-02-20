package health

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"go.uber.org/zap/zaptest"
)

func TestServer_HealthEndpoint(t *testing.T) {
	logger := zaptest.NewLogger(t)
	s := NewServer(0, logger)

	// Create a test request
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()

	s.handleHealth(w, req)

	resp := w.Result()
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("handleHealth() status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	if w.Body.String() != "ok" {
		t.Errorf("handleHealth() body = %q, want %q", w.Body.String(), "ok")
	}
}

func TestServer_HealthEndpoint_MethodNotAllowed(t *testing.T) {
	logger := zaptest.NewLogger(t)
	s := NewServer(0, logger)

	methods := []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch}

	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			req := httptest.NewRequest(method, "/health", nil)
			w := httptest.NewRecorder()

			s.handleHealth(w, req)

			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("handleHealth() with %s status = %d, want %d",
					method, w.Code, http.StatusMethodNotAllowed)
			}
		})
	}
}

func TestServer_ReadyEndpoint(t *testing.T) {
	logger := zaptest.NewLogger(t)
	s := NewServer(0, logger)

	t.Run("ready by default", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/ready", nil)
		w := httptest.NewRecorder()

		s.handleReady(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("handleReady() status = %d, want %d", w.Code, http.StatusOK)
		}
		if w.Body.String() != "ready" {
			t.Errorf("handleReady() body = %q, want %q", w.Body.String(), "ready")
		}
	})

	t.Run("not ready", func(t *testing.T) {
		s.SetReady(false)

		req := httptest.NewRequest(http.MethodGet, "/ready", nil)
		w := httptest.NewRecorder()

		s.handleReady(w, req)

		if w.Code != http.StatusServiceUnavailable {
			t.Errorf("handleReady() status = %d, want %d", w.Code, http.StatusServiceUnavailable)
		}
		if w.Body.String() != "not ready" {
			t.Errorf("handleReady() body = %q, want %q", w.Body.String(), "not ready")
		}
	})

	t.Run("back to ready", func(t *testing.T) {
		s.SetReady(true)

		req := httptest.NewRequest(http.MethodGet, "/ready", nil)
		w := httptest.NewRecorder()

		s.handleReady(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("handleReady() status = %d, want %d", w.Code, http.StatusOK)
		}
	})
}

func TestServer_HeadMethod(t *testing.T) {
	logger := zaptest.NewLogger(t)
	s := NewServer(0, logger)

	t.Run("health HEAD", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodHead, "/health", nil)
		w := httptest.NewRecorder()

		s.handleHealth(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("handleHealth() HEAD status = %d, want %d", w.Code, http.StatusOK)
		}
		// HEAD should not have a body
		if w.Body.Len() != 0 {
			t.Errorf("handleHealth() HEAD body length = %d, want 0", w.Body.Len())
		}
	})

	t.Run("ready HEAD", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodHead, "/ready", nil)
		w := httptest.NewRecorder()

		s.handleReady(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("handleReady() HEAD status = %d, want %d", w.Code, http.StatusOK)
		}
		if w.Body.Len() != 0 {
			t.Errorf("handleReady() HEAD body length = %d, want 0", w.Body.Len())
		}
	})
}

func TestServer_IsReady(t *testing.T) {
	logger := zaptest.NewLogger(t)
	s := NewServer(0, logger)

	if !s.IsReady() {
		t.Error("IsReady() = false, want true (default)")
	}

	s.SetReady(false)
	if s.IsReady() {
		t.Error("IsReady() = true, want false")
	}

	s.SetReady(true)
	if !s.IsReady() {
		t.Error("IsReady() = false, want true")
	}
}

func TestServer_StartAndShutdown(t *testing.T) {
	logger := zaptest.NewLogger(t)

	// Find a free port
	port := 18081

	s := NewServer(port, logger)
	ctx := context.Background()

	// Start server in goroutine
	errChan := make(chan error, 1)
	go func() {
		errChan <- s.Start(ctx)
	}()

	// Wait for server to start
	time.Sleep(100 * time.Millisecond)

	// Test that we can connect
	resp, err := http.Get(fmt.Sprintf("http://localhost:%d/health", port))
	if err != nil {
		t.Fatalf("Failed to connect to health server: %v", err)
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /health status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	// Shutdown
	shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if err := s.Shutdown(shutdownCtx); err != nil {
		t.Errorf("Shutdown() error = %v", err)
	}

	// Server should have stopped without error
	select {
	case err := <-errChan:
		if err != nil {
			t.Errorf("Start() returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Error("Server did not stop after shutdown")
	}
}

func TestServer_ShutdownWithoutStart(t *testing.T) {
	logger := zaptest.NewLogger(t)
	s := NewServer(0, logger)

	ctx := context.Background()
	if err := s.Shutdown(ctx); err != nil {
		t.Errorf("Shutdown() without Start() error = %v", err)
	}
}
