package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestHealthzReturnsOK is the DELIBERATE CONVERGENCE FAILURE for plan task
// T0.13 / the Slice 0 dogfood (T0.12).
//
// It asserts that GET /livez returns the body "ok" -- the same value the live
// http_probe predicate (T0.5b) asserts against a deployed instance. The handler
// currently returns "not-ok" (see healthBody in main.go), so this test FAILS on
// purpose. Do NOT "fix" it by hand: kazi is supposed to converge it by changing
// healthBody from "not-ok" to "ok". When that single edit lands, this test goes
// green and the live probe passes.
func TestHealthzReturnsOK(t *testing.T) {
	const want = "ok"

	srv := httptest.NewServer(newMux())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/livez")
	if err != nil {
		t.Fatalf("GET /livez: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /livez status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}

	if got := string(body); got != want {
		t.Errorf("GET /livez body = %q, want %q (this is the deliberate convergence target -- see README)", got, want)
	}
}

// TestRootResponds is a non-failing sanity check that the service serves the
// root route. It is green today and stays green through convergence.
func TestRootResponds(t *testing.T) {
	srv := httptest.NewServer(newMux())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET / status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
}
