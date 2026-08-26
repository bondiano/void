// Go net/http calibration baseline (SPEC §8.3, ADR-0014) — the
// ceiling of the class, not a competitor. Serves both bench shapes:
// GET / plaintext and POST /echo JSON echo (decode into a typed
// struct + encode back, the closest analogue of B1's
// parse+validate+serialize). The runner sets GOMAXPROCS=1 — budgets
// are per 1 worker / 1 vCPU.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type Address struct {
	Street  string `json:"street"`
	City    string `json:"city"`
	Zip     string `json:"zip"`
	Country string `json:"country"`
}

type Customer struct {
	Name    string  `json:"name"`
	Email   string  `json:"email"`
	Address Address `json:"address"`
}

type Item struct {
	Sku   string  `json:"sku"`
	Name  string  `json:"name"`
	Qty   int     `json:"qty"`
	Price float64 `json:"price"`
}

type Order struct {
	ID       int      `json:"id"`
	Currency string   `json:"currency"`
	Customer Customer `json:"customer"`
	Items    []Item   `json:"items"`
	Note     string   `json:"note,omitempty"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8180"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("Hello, World!"))
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		var o Order
		if err := json.NewDecoder(r.Body).Decode(&o); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if err := json.NewEncoder(w).Encode(o); err != nil {
			log.Println("encode:", err)
		}
	})
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, mux))
}
