package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"notebank/server"
)

func main() {
	databaseURL := os.Getenv(server.EnvDatabaseURL)
	listenAddr := os.Getenv(server.EnvListenAddr)
	if listenAddr == "" {
		listenAddr = server.DefaultListenAddr
	}
	if databaseURL == "" {
		log.Fatalf("%s is required", server.EnvDatabaseURL)
	}
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		log.Fatalf("%s: %v", server.EnvDatabaseURL, err)
	}
	defer db.Close()
	handler, err := server.New(server.Config{Secret: os.Getenv(server.EnvSecret), Now: time.Now, DB: db})
	if err != nil {
		log.Fatalf("%s: %v", server.EnvSecret, err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := server.Migrate(ctx, db); err != nil {
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
