// Package health provides HTTP health check endpoints for Kubernetes probes.
package health

import (
	"context"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

	"go.uber.org/zap"
)

// Server provides health check endpoints.
type Server struct {
	port   int
	logger *zap.Logger
	server *http.Server
	ready  atomic.Bool
}

// NewServer creates a new health check server.
func NewServer(port int, logger *zap.Logger) *Server {
	s := &Server{
		port:   port,
		logger: logger,
	}
	s.ready.Store(true)
	return s
}

// Start begins serving health endpoints. This method blocks until the server
// is shut down or encounters an error.
func (s *Server) Start(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/ready", s.handleReady)

	s.server = &http.Server{
		Addr:              fmt.Sprintf(":%d", s.port),
		Handler:           mux,
		ReadTimeout:       5 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	s.logger.Info("health server starting", zap.Int("port", s.port))

	if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		s.logger.Error("health server error", zap.Error(err))
		return err
	}

	return nil
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	s.ready.Store(false)

	if s.server == nil {
		return nil
	}

	shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	s.logger.Info("health server shutting down")
	return s.server.Shutdown(shutdownCtx)
}

// SetReady updates the readiness status.
func (s *Server) SetReady(ready bool) {
	s.ready.Store(ready)
}

// IsReady returns the current readiness status.
func (s *Server) IsReady() bool {
	return s.ready.Load()
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		_, _ = w.Write([]byte("ok"))
	}
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")

	if s.ready.Load() {
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte("ready"))
		}
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte("not ready"))
		}
	}
}
