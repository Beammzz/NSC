// Package webui embeds and serves the compiled Next.js admin interface.
// dist/ is the static export produced by `npm run build` in Backend/webui
// (which writes here); it is embedded into the server binary at compile
// time, so the deployed artifact is a single Go binary.
package webui

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed all:dist
var dist embed.FS

// Handler serves the embedded webui (mounted at "/"; API routes win by
// mux specificity).
func Handler() http.Handler {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		panic(err) // embedded path is fixed at compile time
	}
	return http.FileServerFS(sub)
}
