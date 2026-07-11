package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Token lifetimes per root DOX contract.
const (
	AccessTokenLifetime  = 15 * time.Minute
	RefreshTokenLifetime = 30 * 24 * time.Hour // 30 days
)

// Claims are the JWT payload fields carried in the access token.
type Claims struct {
	Sub   int64  `json:"sub"`   // user ID
	Email string `json:"email"`
	Role  string `json:"role"`
	Exp   int64  `json:"exp"`   // unix seconds
	Iat   int64  `json:"iat"`   // unix seconds
}

var (
	ErrTokenExpired  = errors.New("token expired")
	ErrTokenInvalid  = errors.New("token invalid")
	ErrTokenMalform  = errors.New("token malformed")
)

// GenerateAccessToken creates a signed HMAC-SHA256 JWT.
func GenerateAccessToken(userID int64, email, role string, secret []byte) (string, error) {
	now := time.Now()
	claims := Claims{
		Sub:   userID,
		Email: email,
		Role:  role,
		Exp:   now.Add(AccessTokenLifetime).Unix(),
		Iat:   now.Unix(),
	}
	return signJWT(claims, secret)
}

// ValidateAccessToken parses and verifies an HMAC-SHA256 JWT, returning
// the claims on success.
func ValidateAccessToken(tokenStr string, secret []byte) (Claims, error) {
	parts := strings.Split(tokenStr, ".")
	if len(parts) != 3 {
		return Claims{}, ErrTokenMalform
	}

	// Verify signature first.
	signInput := parts[0] + "." + parts[1]
	sig, err := base64URLDecode(parts[2])
	if err != nil {
		return Claims{}, ErrTokenMalform
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(signInput))
	expected := mac.Sum(nil)
	if !hmac.Equal(sig, expected) {
		return Claims{}, ErrTokenInvalid
	}

	// Decode claims.
	payload, err := base64URLDecode(parts[1])
	if err != nil {
		return Claims{}, ErrTokenMalform
	}
	var claims Claims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return Claims{}, ErrTokenMalform
	}

	// Check expiry.
	if time.Now().Unix() > claims.Exp {
		return Claims{}, ErrTokenExpired
	}

	return claims, nil
}

// GenerateRefreshToken creates a cryptographically random 32-byte token
// encoded as base64url (no padding).
func GenerateRefreshToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating refresh token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// GenerateRandomSecret creates a cryptographically random 32-byte secret
// for HMAC-SHA256 signing. Used in Dev mode when no secret is configured.
func GenerateRandomSecret() ([]byte, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("generating JWT secret: %w", err)
	}
	return b, nil
}

// ---- internal JWT helpers ----

// jwtHeader is the fixed {"alg":"HS256","typ":"JWT"} header, pre-encoded.
var jwtHeaderB64 = base64URLEncode([]byte(`{"alg":"HS256","typ":"JWT"}`))

func signJWT(claims Claims, secret []byte) (string, error) {
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("encoding claims: %w", err)
	}
	payloadB64 := base64URLEncode(payload)
	signInput := jwtHeaderB64 + "." + payloadB64

	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(signInput))
	sig := base64URLEncode(mac.Sum(nil))

	return signInput + "." + sig, nil
}

func base64URLEncode(data []byte) string {
	return base64.RawURLEncoding.EncodeToString(data)
}

func base64URLDecode(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(s)
}
