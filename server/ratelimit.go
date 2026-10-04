package server

import (
	"sync"
	"time"
)

// failureLimiter counts failed auth attempts per IP in a fixed window that starts at the first failure.
type failureLimiter struct {
	mu        sync.Mutex
	now       func() time.Time
	windows   map[string]failureWindow
	lastSweep time.Time
}

type failureWindow struct {
	start    time.Time
	failures int
}

func (w failureWindow) expired(now time.Time) bool {
	return !now.Before(w.start.Add(authFailureWindow))
}

func newFailureLimiter(now func() time.Time) *failureLimiter {
	return &failureLimiter{now: now, windows: map[string]failureWindow{}}
}

func (l *failureLimiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w, ok := l.windows[ip]
	return ok && w.failures >= maxAuthFailures && !w.expired(l.now())
}

func (l *failureLimiter) recordFailure(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.sweep(now)
	w, ok := l.windows[ip]
	if !ok || w.expired(now) {
		w = failureWindow{start: now}
	}
	w.failures++
	l.windows[ip] = w
}

// sweep drops expired windows so many one-off IPs can't grow the map forever.
func (l *failureLimiter) sweep(now time.Time) {
	if now.Sub(l.lastSweep) < authFailureWindow {
		return
	}
	l.lastSweep = now
	for ip, w := range l.windows {
		if w.expired(now) {
			delete(l.windows, ip)
		}
	}
}
