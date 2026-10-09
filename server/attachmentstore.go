package server

import (
	"crypto/rand"
	"errors"
	"io"
	"os"
)

// attachmentStore keeps Attachment files and thumbnails in one directory, named by opaque keys.
// os.Root refuses any key that would resolve outside that directory, symlinks included.
type attachmentStore struct{ root *os.Root }

func openAttachmentStore(dir string) (*attachmentStore, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	return &attachmentStore{root: root}, nil
}

var errSizeMismatch = errors.New("file size does not match the declared size")

// Put stores r under key only if it holds exactly sizeBytes, so a key never names a partial file.
func (s *attachmentStore) Put(key string, r io.Reader, sizeBytes int64) (err error) {
	// The suffix can't collide with a key and marks leftovers of a crash for cleanup.
	tmp := key + ".partial-" + rand.Text()
	f, err := s.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			f.Close() // harmless if already closed
			s.root.Remove(tmp)
		}
	}()

	n, err := io.Copy(f, io.LimitReader(r, sizeBytes+1))
	if err != nil {
		return err
	}
	if n != sizeBytes {
		return errSizeMismatch
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return s.root.Rename(tmp, key)
}

func (s *attachmentStore) Open(key string) (*os.File, error) {
	return s.root.Open(key)
}
