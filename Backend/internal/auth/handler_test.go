package auth

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func testHandler(t *testing.T) *Handler {
	t.Helper()
	s := testStore(t)
	secret := []byte("test-secret-32-bytes-long-enough")
	loginRL := NewRateLimiter(5, time.Minute)
	signupRL := NewRateLimiter(10, 24*time.Hour)
	return NewHandler(s, secret, true, false, loginRL, signupRL) // allowSignup=true, trustProxy=false
}

func doJSON(t *testing.T, handler http.HandlerFunc, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encoding body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	return rr
}

func TestJWTRoundTrip(t *testing.T) {
	secret := []byte("test-secret-32-bytes-long-enough")
	tok, err := GenerateAccessToken(42, "test@example.com", RoleUser, secret)
	if err != nil {
		t.Fatalf("GenerateAccessToken: %v", err)
	}

	claims, err := ValidateAccessToken(tok, secret)
	if err != nil {
		t.Fatalf("ValidateAccessToken: %v", err)
	}
	if claims.Sub != 42 {
		t.Fatalf("expected sub=42, got %d", claims.Sub)
	}
	if claims.Email != "test@example.com" {
		t.Fatalf("expected email test@example.com, got %q", claims.Email)
	}
	if claims.Role != RoleUser {
		t.Fatalf("expected role %q, got %q", RoleUser, claims.Role)
	}
}

func TestJWTWrongSecret(t *testing.T) {
	secret := []byte("test-secret-32-bytes-long-enough")
	tok, _ := GenerateAccessToken(1, "a@b.com", RoleUser, secret)

	_, err := ValidateAccessToken(tok, []byte("wrong-secret-000000000000000000"))
	if err != ErrTokenInvalid {
		t.Fatalf("expected ErrTokenInvalid, got %v", err)
	}
}

func TestJWTMalformed(t *testing.T) {
	secret := []byte("test-secret-32-bytes-long-enough")
	_, err := ValidateAccessToken("not.a.jwt.at.all", secret)
	if err == nil {
		t.Fatal("expected error on malformed token")
	}
}

func TestSignupAndLogin(t *testing.T) {
	h := testHandler(t)

	// Signup.
	rr := doJSON(t, h.signup, "POST", "/api/v1/auth/signup", signupRequest{
		Email:    "new@example.com",
		Password: "Strong1pw",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("signup: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var signupResp authResponse
	if err := json.NewDecoder(rr.Body).Decode(&signupResp); err != nil {
		t.Fatalf("decoding signup response: %v", err)
	}
	if signupResp.User.Email != "new@example.com" {
		t.Fatalf("expected email in response, got %q", signupResp.User.Email)
	}
	if signupResp.AccessToken == "" {
		t.Fatal("expected access token in response")
	}

	// Login.
	rr = doJSON(t, h.login, "POST", "/api/v1/auth/login", loginRequest{
		Email:    "new@example.com",
		Password: "Strong1pw",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("login: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var loginResp authResponse
	_ = json.NewDecoder(rr.Body).Decode(&loginResp)
	if loginResp.User.Role != RoleUser {
		t.Fatalf("expected role %q, got %q", RoleUser, loginResp.User.Role)
	}
}

func TestLoginWrongPassword(t *testing.T) {
	h := testHandler(t)

	_, _ = h.store.CreateUser("wp@example.com", "Correct1", RoleUser)

	rr := doJSON(t, h.login, "POST", "/api/v1/auth/login", loginRequest{
		Email:    "wp@example.com",
		Password: "Wrong1234",
	})
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rr.Code)
	}
}

func TestLoginNonExistentUser(t *testing.T) {
	h := testHandler(t)

	rr := doJSON(t, h.login, "POST", "/api/v1/auth/login", loginRequest{
		Email:    "ghost@example.com",
		Password: "Password1",
	})
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rr.Code)
	}
}

func TestSignupWeakPassword(t *testing.T) {
	h := testHandler(t)

	cases := []struct {
		name string
		pw   string
	}{
		{"too short", "Ab1"},
		{"no uppercase", "password1"},
		{"no lowercase", "PASSWORD1"},
		{"no digit", "Passwordd"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rr := doJSON(t, h.signup, "POST", "/api/v1/auth/signup", signupRequest{
				Email:    "weak@example.com",
				Password: tc.pw,
			})
			if rr.Code != http.StatusBadRequest {
				t.Fatalf("expected 400 for %q, got %d: %s", tc.pw, rr.Code, rr.Body.String())
			}
		})
	}
}

func TestSignupDuplicateEmail(t *testing.T) {
	h := testHandler(t)

	doJSON(t, h.signup, "POST", "/api/v1/auth/signup", signupRequest{
		Email: "dup@example.com", Password: "Strong1pw",
	})
	rr := doJSON(t, h.signup, "POST", "/api/v1/auth/signup", signupRequest{
		Email: "dup@example.com", Password: "Strong2pw",
	})
	if rr.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", rr.Code)
	}
}

func TestPasswordValidation(t *testing.T) {
	if err := validatePassword("GoodPass1"); err != nil {
		t.Fatalf("expected valid password: %v", err)
	}
	if err := validatePassword("short"); err == nil {
		t.Fatal("expected error for short password")
	}
}

func TestRateLimiter(t *testing.T) {
	rl := NewRateLimiter(3, time.Minute)
	for i := 0; i < 3; i++ {
		if !rl.Allow("test-ip") {
			t.Fatalf("expected allow on attempt %d", i+1)
		}
	}
	if rl.Allow("test-ip") {
		t.Fatal("expected deny after limit reached")
	}
	// Different key should still be allowed.
	if !rl.Allow("other-ip") {
		t.Fatal("expected allow for different key")
	}
}

func TestRateLimitIgnoresSpoofedXFFByDefault(t *testing.T) {
	rl := NewRateLimiter(1, time.Minute)
	handler := RateLimitMiddleware(rl, false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	for i, want := range []int{http.StatusOK, http.StatusTooManyRequests} {
		req := httptest.NewRequest("POST", "/login", nil)
		req.RemoteAddr = "10.0.0.1:1234"
		// A fresh spoofed XFF per request must NOT mint a fresh bucket.
		req.Header.Set("X-Forwarded-For", "1.2.3."+string(rune('0'+i)))
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("request %d: expected %d, got %d", i+1, want, rec.Code)
		}
	}
}

func TestRateLimitUsesXFFWhenProxyTrusted(t *testing.T) {
	rl := NewRateLimiter(1, time.Minute)
	handler := RateLimitMiddleware(rl, true)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	// Same proxy RemoteAddr, distinct forwarded clients: both allowed.
	for _, xff := range []string{"1.2.3.4", "5.6.7.8"} {
		req := httptest.NewRequest("POST", "/login", nil)
		req.RemoteAddr = "10.0.0.1:1234"
		req.Header.Set("X-Forwarded-For", xff)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("xff %s: expected 200, got %d", xff, rec.Code)
		}
	}
}

func TestRateLimiterSweepsIdleKeys(t *testing.T) {
	rl := NewRateLimiter(1, 10*time.Millisecond)
	rl.Allow("idle-key")
	time.Sleep(25 * time.Millisecond)
	rl.Allow("other-key") // triggers the sweep

	rl.mu.Lock()
	_, exists := rl.entries["idle-key"]
	rl.mu.Unlock()
	if exists {
		t.Fatal("expected idle-key to be swept from the entries map")
	}
}

func TestLogoutClearsCookiesWithMatchingPaths(t *testing.T) {
	h := testHandler(t)

	req := httptest.NewRequest("POST", "/api/v1/auth/logout", nil)
	rec := httptest.NewRecorder()
	h.logout(rec, req)

	paths := map[string]string{}
	for _, c := range rec.Result().Cookies() {
		paths[c.Name] = c.Path
		if c.MaxAge >= 0 {
			t.Fatalf("cookie %s: expected deletion (MaxAge<0), got %d", c.Name, c.MaxAge)
		}
	}
	if paths["signmind_access"] != "/" {
		t.Fatalf("signmind_access cleared with path %q, want /", paths["signmind_access"])
	}
	if paths["signmind_refresh"] != refreshCookiePath {
		t.Fatalf("signmind_refresh cleared with path %q, want %q",
			paths["signmind_refresh"], refreshCookiePath)
	}
}

func TestCookieSecureFollowsRequestScheme(t *testing.T) {
	h := testHandler(t)
	_, _ = h.store.CreateUser("sec@example.com", "Password1", RoleUser)

	login := func(forwardedProto string) []*http.Cookie {
		var buf bytes.Buffer
		_ = json.NewEncoder(&buf).Encode(loginRequest{Email: "sec@example.com", Password: "Password1"})
		req := httptest.NewRequest("POST", "/api/v1/auth/login", &buf)
		req.Header.Set("Content-Type", "application/json")
		if forwardedProto != "" {
			req.Header.Set("X-Forwarded-Proto", forwardedProto)
		}
		rec := httptest.NewRecorder()
		h.login(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("login: expected 200, got %d: %s", rec.Code, rec.Body.String())
		}
		return rec.Result().Cookies()
	}

	for _, c := range login("") {
		if c.Secure {
			t.Fatalf("cookie %s: Secure set on plain-HTTP request", c.Name)
		}
	}
	for _, c := range login("https") {
		if !c.Secure {
			t.Fatalf("cookie %s: Secure missing on forwarded-HTTPS request", c.Name)
		}
	}
}

func TestMeEndpoint(t *testing.T) {
	h := testHandler(t)

	// Create user and get token.
	_, _ = h.store.CreateUser("me@example.com", "Password1", RoleAdmin)

	rr := doJSON(t, h.login, "POST", "/api/v1/auth/login", loginRequest{
		Email: "me@example.com", Password: "Password1",
	})
	var resp authResponse
	_ = json.NewDecoder(rr.Body).Decode(&resp)

	// Call /me with Bearer token.
	req := httptest.NewRequest("GET", "/api/v1/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+resp.AccessToken)
	rec := httptest.NewRecorder()

	// Wire through RequireAuth middleware.
	handler := RequireAuth(h.secret)(http.HandlerFunc(h.me))
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestMiddlewareRejectsNoToken(t *testing.T) {
	secret := []byte("test-secret-32-bytes-long-enough")
	handler := RequireAuth(secret)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/protected", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRequireRoleForbids(t *testing.T) {
	secret := []byte("test-secret-32-bytes-long-enough")
	tok, _ := GenerateAccessToken(1, "user@example.com", RoleUser, secret)

	handler := RequireAuth(secret)(RequireRole(RoleAdmin)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})))

	req := httptest.NewRequest("GET", "/admin-only", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}
