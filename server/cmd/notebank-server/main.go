package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"notebank/server"
)

func main() {
	databaseURL := os.Getenv(server.EnvDatabaseURL)
	listenAddr := os.Getenv(server.EnvListenAddr)
	if listenAddr == "" {
		listenAddr = server.DefaultListenAddr
	}
	attachmentDir := os.Getenv(server.EnvAttachmentDir)
	if databaseURL == "" || attachmentDir == "" {
		log.Fatalf("%s and %s are required", server.EnvDatabaseURL, server.EnvAttachmentDir)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		log.Fatalf("%s: %v", server.EnvDatabaseURL, err)
	}
	defer pool.Close()
	handler, err := server.New(server.Config{Secret: os.Getenv(server.EnvSecret), Now: time.Now, DB: pool, AttachmentDir: attachmentDir})
	if err != nil {
		log.Fatalf("check %s and %s: %v", server.EnvSecret, server.EnvAttachmentDir, err)
	}

	if err := server.Migrate(ctx, pool); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           handler,
		ReadHeaderTimeout: server.ReadHeaderTimeout,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), server.ShutdownTimeout)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()

	log.Printf("listening on %s", listenAddr)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
