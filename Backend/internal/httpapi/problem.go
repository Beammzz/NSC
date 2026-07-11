// Package httpapi holds shared HTTP API plumbing: RFC 7807 error responses.
package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
)

// Problem is an RFC 7807 Problem Details body (root DOX error contract).
type Problem struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int    `json:"status"`
	Detail string `json:"detail,omitempty"`
}

// NewProblem builds a Problem with the default "about:blank" type.
func NewProblem(status int, title, detail string) Problem {
	return Problem{Type: "about:blank", Title: title, Status: status, Detail: detail}
}

// WriteProblem renders p as an application/problem+json HTTP response.
func WriteProblem(w http.ResponseWriter, p Problem) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(p.Status)
	if err := json.NewEncoder(w).Encode(p); err != nil {
		log.Printf("httpapi: writing problem response: %v", err)
	}
}
