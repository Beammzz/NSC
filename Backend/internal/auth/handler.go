package auth

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
)

// Handler serves the /api/v1/auth/* REST endpoints and the admin-only
// /api/v1/admin/users/* user management endpoints.
type Handler struct {
	store       *Store
	secret      []byte
	allowSignup bool
	trustProxy  bool
	loginRL     *RateLimiter
	signupRL    *RateLimiter
}

// NewHandler creates an auth handler. loginRL limits login attempts;
// signupRL limits account creation (10/day/IP by default). trustProxy
// gates X-Forwarded-For as the rate-limit key (see RateLimitMiddleware).
func NewHandler(store *Store, secret []byte, allowSignup, trustProxy bool, loginRL, signupRL *RateLimiter) *Handler {
	return &Handler{
		store:       store,
		secret:      secret,
		allowSignup: allowSignup,
		trustProxy:  trustProxy,
		loginRL:     loginRL,
		signupRL:    signupRL,
	}
}

// Register mounts auth routes on mux. Admin user-management routes are
// protected by the provided auth+role middleware chain.
func (h *Handler) Register(mux *http.ServeMux, adminMW func(http.Handler) http.Handler) {
	// Public auth endpoints (rate-limited).
	loginHandler := RateLimitMiddleware(h.loginRL, h.trustProxy)(http.HandlerFunc(h.login))
	mux.Handle("POST /api/v1/auth/login", loginHandler)
	mux.HandleFunc("POST /api/v1/auth/refresh", h.refresh)
	mux.HandleFunc("POST /api/v1/auth/logout", h.logout)

	// Signup: public if AllowSignup, otherwise admin-only.
	signupHandler := RateLimitMiddleware(h.signupRL, h.trustProxy)(http.HandlerFunc(h.signup))
	if h.allowSignup {
		mux.Handle("POST /api/v1/auth/signup", signupHandler)
	} else {
		mux.Handle("POST /api/v1/auth/signup", adminMW(signupHandler))
	}

	// Authenticated: current user info.
	mux.Handle("GET /api/v1/auth/me", RequireAuth(h.secret)(http.HandlerFunc(h.me)))

	// Admin-only user management.
	mux.Handle("GET /api/v1/admin/users", adminMW(http.HandlerFunc(h.listUsers)))
	mux.Handle("POST /api/v1/admin/users", adminMW(http.HandlerFunc(h.createUser)))
	mux.Handle("DELETE /api/v1/admin/users/{id}", adminMW(http.HandlerFunc(h.deleteUser)))
}

// ---- login ----

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type authResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token,omitempty"`
	ExpiresIn    int    `json:"expires_in"`
	User         User   `json:"user"`
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) {
	var body loginRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed request body", err.Error()))
		return
	}
	body.Email = strings.TrimSpace(body.Email)
	if body.Email == "" || body.Password == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Missing credentials",
			"email and password are required"))
		return
	}

	// Constant-time: always hash-compare even if user not found, to prevent
	// timing-based user enumeration.
	user, err := h.store.GetUserByEmail(body.Email)
	if err != nil {
		// Burn time on a dummy bcrypt compare so the response latency is
		// indistinguishable from a real password check.
		_ = CheckPassword("$2a$12$000000000000000000000000000000000000000000000000000000", body.Password)
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Invalid credentials",
			"email or password is incorrect"))
		return
	}
	if err := CheckPassword(user.PasswordHash, body.Password); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Invalid credentials",
			"email or password is incorrect"))
		return
	}

	h.issueTokens(w, r, user)
}

// ---- signup ----

var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$`)

type signupRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (h *Handler) signup(w http.ResponseWriter, r *http.Request) {
	var body signupRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed request body", err.Error()))
		return
	}
	body.Email = strings.TrimSpace(body.Email)
	if !emailRegex.MatchString(body.Email) {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid email format",
			"provide a valid email address"))
		return
	}
	if err := validatePassword(body.Password); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Weak password", err.Error()))
		return
	}

	// Public signup always creates "user" role — only admins can create admins.
	user, err := h.store.CreateUser(body.Email, body.Password, RoleUser)
	if err != nil {
		if strings.Contains(err.Error(), "email already registered") {
			httpapi.WriteProblem(w, httpapi.NewProblem(
				http.StatusConflict, "Email already registered",
				"an account with this email already exists"))
			return
		}
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "User creation failed", err.Error()))
		return
	}

	log.Printf("auth: new user signup id=%d email=%s", user.ID, user.Email)
	h.issueTokens(w, r, user)
}

// ---- refresh ----

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	rawToken := ""

	// Accept from cookie first, then JSON body.
	if c, err := r.Cookie("signmind_refresh"); err == nil {
		rawToken = c.Value
	} else {
		var body refreshRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			rawToken = body.RefreshToken
		}
	}
	if rawToken == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Missing refresh token",
			"provide a refresh token via cookie or request body"))
		return
	}

	tokenHash := HashToken(rawToken)
	rt, err := h.store.FindRefreshToken(tokenHash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			httpapi.WriteProblem(w, httpapi.NewProblem(
				http.StatusUnauthorized, "Invalid refresh token",
				"token not found or already revoked"))
			return
		}
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Token lookup failed", err.Error()))
		return
	}

	// Check expiry.
	if time.Now().UnixMilli() > rt.ExpiresAt {
		_ = h.store.DeleteRefreshToken(tokenHash)
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Refresh token expired",
			"please log in again"))
		return
	}

	// Revoke old token (rotation).
	_ = h.store.DeleteRefreshToken(tokenHash)

	user, err := h.store.GetUserByID(rt.UserID)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "User not found",
			"the user associated with this token no longer exists"))
		return
	}

	h.issueTokens(w, r, user)
}

// ---- logout ----

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	// Revoke refresh token from cookie or body.
	rawToken := ""
	if c, err := r.Cookie("signmind_refresh"); err == nil {
		rawToken = c.Value
	} else {
		var body refreshRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			rawToken = body.RefreshToken
		}
	}
	if rawToken != "" {
		if err := h.store.DeleteRefreshToken(HashToken(rawToken)); err != nil {
			log.Printf("auth: revoking refresh token on logout: %v", err)
		}
	}

	// Clear cookies. Each must be cleared with the same Path it was set
	// with — browsers key cookies by (name, domain, path).
	secure := requestIsSecure(r)
	clearCookie(w, "signmind_access", "/", secure)
	clearCookie(w, "signmind_refresh", refreshCookiePath, secure)

	w.WriteHeader(http.StatusNoContent)
}

// ---- me ----

func (h *Handler) me(w http.ResponseWriter, r *http.Request) {
	claims, ok := ClaimsFromContext(r.Context())
	if !ok {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Authentication required", ""))
		return
	}
	writeJSON(w, struct {
		ID    int64  `json:"id"`
		Email string `json:"email"`
		Role  string `json:"role"`
	}{claims.Sub, claims.Email, claims.Role})
}

// ---- admin user management ----

func (h *Handler) listUsers(w http.ResponseWriter, r *http.Request) {
	users, err := h.store.ListUsers()
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "User list failed", err.Error()))
		return
	}
	writeJSON(w, struct {
		Users []User `json:"users"`
	}{users})
}

type createUserRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Role     string `json:"role"`
}

func (h *Handler) createUser(w http.ResponseWriter, r *http.Request) {
	var body createUserRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed request body", err.Error()))
		return
	}
	body.Email = strings.TrimSpace(body.Email)
	if !emailRegex.MatchString(body.Email) {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid email format",
			"provide a valid email address"))
		return
	}
	if err := validatePassword(body.Password); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Weak password", err.Error()))
		return
	}
	role := body.Role
	if role != RoleAdmin && role != RoleUser {
		role = RoleUser
	}

	user, err := h.store.CreateUser(body.Email, body.Password, role)
	if err != nil {
		if strings.Contains(err.Error(), "email already registered") {
			httpapi.WriteProblem(w, httpapi.NewProblem(
				http.StatusConflict, "Email already registered",
				"an account with this email already exists"))
			return
		}
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "User creation failed", err.Error()))
		return
	}

	log.Printf("auth: admin created user id=%d email=%s role=%s", user.ID, user.Email, user.Role)
	w.WriteHeader(http.StatusCreated)
	writeJSON(w, user)
}

func (h *Handler) deleteUser(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid user ID",
			"id must be a positive integer"))
		return
	}

	// Prevent self-deletion.
	claims, _ := ClaimsFromContext(r.Context())
	if claims.Sub == id {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusForbidden, "Cannot delete yourself",
			"you cannot delete your own account"))
		return
	}

	if err := h.store.DeleteUser(id); err != nil {
		if strings.Contains(err.Error(), "user not found") {
			httpapi.WriteProblem(w, httpapi.NewProblem(
				http.StatusNotFound, "User not found",
				"no user with that ID exists"))
			return
		}
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "User deletion failed", err.Error()))
		return
	}

	log.Printf("auth: admin deleted user id=%d", id)
	w.WriteHeader(http.StatusNoContent)
}

// ---- helpers ----

// issueTokens generates access + refresh tokens, sets cookies, and writes
// the JSON response.
func (h *Handler) issueTokens(w http.ResponseWriter, r *http.Request, user User) {
	accessToken, err := GenerateAccessToken(user.ID, user.Email, user.Role, h.secret)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Token generation failed", err.Error()))
		return
	}

	refreshToken, err := GenerateRefreshToken()
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Token generation failed", err.Error()))
		return
	}

	expiresAt := time.Now().Add(RefreshTokenLifetime).UnixMilli()
	if err := h.store.InsertRefreshToken(user.ID, HashToken(refreshToken), expiresAt); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Token storage failed", err.Error()))
		return
	}

	// Set HttpOnly cookies for webui.
	setTokenCookies(w, accessToken, refreshToken, requestIsSecure(r))

	writeJSON(w, authResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    int(AccessTokenLifetime.Seconds()),
		User:         user,
	})
}

// refreshCookiePath scopes the refresh cookie to the auth endpoints only.
const refreshCookiePath = "/api/v1/auth/"

// requestIsSecure reports whether the request arrived over HTTPS, directly
// (TLS) or via a reverse proxy (X-Forwarded-Proto). Browsers drop
// Secure cookies on plain-HTTP origins other than localhost, so marking
// cookies Secure unconditionally breaks webui login on LAN deployments.
func requestIsSecure(r *http.Request) bool {
	return r.TLS != nil ||
		strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func setTokenCookies(w http.ResponseWriter, access, refresh string, secure bool) {
	http.SetCookie(w, &http.Cookie{
		Name:     "signmind_access",
		Value:    access,
		Path:     "/",
		MaxAge:   int(AccessTokenLifetime.Seconds()),
		HttpOnly: true,
		Secure:   secure,
		SameSite: http.SameSiteStrictMode,
	})
	http.SetCookie(w, &http.Cookie{
		Name:     "signmind_refresh",
		Value:    refresh,
		Path:     refreshCookiePath,
		MaxAge:   int(RefreshTokenLifetime.Seconds()),
		HttpOnly: true,
		Secure:   secure,
		SameSite: http.SameSiteStrictMode,
	})
}

func clearCookie(w http.ResponseWriter, name, path string, secure bool) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    "",
		Path:     path,
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   secure,
		SameSite: http.SameSiteStrictMode,
	})
}

func validatePassword(pw string) error {
	if len(pw) < 8 {
		return errors.New("password must be at least 8 characters")
	}
	var hasUpper, hasLower, hasDigit bool
	for _, c := range pw {
		switch {
		case unicode.IsUpper(c):
			hasUpper = true
		case unicode.IsLower(c):
			hasLower = true
		case unicode.IsDigit(c):
			hasDigit = true
		}
	}
	if !hasUpper {
		return errors.New("password must contain at least one uppercase letter")
	}
	if !hasLower {
		return errors.New("password must contain at least one lowercase letter")
	}
	if !hasDigit {
		return errors.New("password must contain at least one digit")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("auth: writing JSON response: %v", err)
	}
}
