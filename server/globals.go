package server

import "time"

// Every limit, timeout and default the Server uses. Tests keep their own values.
const (
	// Auth
	minSecretChars    = 32
	maxAuthFailures   = 10
	authFailureWindow = 15 * time.Minute

	// Sync
	maxPushOps        = 500
	maxPushBodyBytes  = 16 << 20
	pullPageSize      = 500
	maxItemTextBytes  = 1 << 20
	maxTopicNameBytes = 200

	// Attachments
	maxAttachmentBytes       = 100 << 20
	maxAttachmentFieldBytes  = 255 // filename and mime type
	thumbnailEdgePixels      = 400
	thumbnailJPEGQuality     = 80
	maxThumbnailSourcePixels = 64 << 20 // above a 48 MP phone photo; decoding takes 4–8 bytes per pixel

	// HTTP server (used by cmd/notebank-server)
	DefaultListenAddr = "127.0.0.1:8080"
	ReadHeaderTimeout = 10 * time.Second
	ShutdownTimeout   = 10 * time.Second
)

// Environment variable names. Values are per-installation and never live in code.
const (
	EnvDatabaseURL   = "NOTEBANK_DATABASE_URL"
	EnvSecret        = "NOTEBANK_SECRET"
	EnvListenAddr    = "NOTEBANK_LISTEN_ADDR"
	EnvAttachmentDir = "NOTEBANK_ATTACHMENT_DIR"
)
