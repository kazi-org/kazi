// Package main is the kazi Slice 0 deployable target fixture: a tiny web
// service that kazi drives from a failing test to a live Cloud Run deployment.
//
// This is SAMPLE TARGET code, NOT part of the kazi application. Its unit test
// (main_test.go) FAILS deliberately -- that failure is the convergence target
// for the Slice 0 dogfood (plan task T0.12). See README.md for what "converged"
// looks like.
package main

import (
	"fmt"
	"net/http"
	"os"
)

// healthBody is the body returned by GET /livez.
//
// The live probe (the http_probe predicate, plan task T0.5b) and the unit test
// both assert that this endpoint returns "ok". It currently returns "not-ok",
// so the test fails and a deployed instance would fail the live probe. The
// convergence target is to change this constant to "ok": once that single edit
// lands, the unit test passes AND the live probe passes.
const healthBody = "ok"

func healthzHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, healthBody)
}

func rootHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "kazi deploy-target fixture\n")
}

// newMux wires the routes. Exposed as a helper so the unit test can exercise
// the handlers without binding a real port.
func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	// NOTE: the liveness route is /livez, NOT /healthz. Cloud Run's front end
	// intercepts the exact path /healthz (returns its own 404; the request never
	// reaches the container), so the live probe could never see it. See
	// docs/lore.md L-0003.
	mux.HandleFunc("/livez", healthzHandler)
	mux.HandleFunc("/", rootHandler)
	return mux
}

func main() {
	// Cloud Run sets $PORT (default 8080) and routes traffic to it.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	addr := ":" + port
	fmt.Printf("kazi deploy-target listening on %s\n", addr)
	if err := http.ListenAndServe(addr, newMux()); err != nil {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}
