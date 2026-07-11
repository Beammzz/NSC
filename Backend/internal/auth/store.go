// Package auth implements JWT authentication, user management, and HTTP
// middleware for the SignMind backend. Passwords are hashed with bcrypt;
// refresh tokens are stored SHA-256 hashed and are revocable. See root
// AGENTS.md §Auth and Backend/AGENTS.md §Local Contracts.
package auth

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// bcryptCost is the bcrypt work factor. 12 takes ~250 ms on modern
// hardware — good balance between brute-force resistance and login UX.
const bcryptCost = 12

const authSchema = `
CREATE TABLE IF NOT EXISTS users (
	id            INTEGER PRIMARY KEY AUTOINCREMENT,
	email         TEXT    NOT NULL UNIQUE COLLATE NOCASE,
	password_hash TEXT    NOT NULL,
	role          TEXT    NOT NULL DEFAULT 'user',
	created_at    INTEGER NOT NULL,
	updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	token_hash TEXT    NOT NULL UNIQUE,
	expires_at INTEGER NOT NULL,
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens(token_hash);
`

// Role constants.
const (
	RoleAdmin = "admin"
	RoleUser  = "user"
)

// User is a persisted user account.
type User struct {
	ID           int64  `json:"id"`
	Email        string `json:"email"`
	PasswordHash string `json:"-"` // never serialized
	Role         string `json:"role"`
	CreatedAt    int64  `json:"created_at"`
	UpdatedAt    int64  `json:"updated_at"`
}

// RefreshToken is a persisted (hashed) refresh token.
type RefreshToken struct {
	ID        int64
	UserID    int64
	TokenHash string
	ExpiresAt int64
	CreatedAt int64
}

// Store manages user and refresh token persistence in SQLite.
type Store struct {
	db *sql.DB
}

// OpenStore applies the auth schema to an existing *sql.DB (shared with
// predlog — WAL mode handles concurrent readers). The caller owns the DB
// lifetime.
func OpenStore(db *sql.DB) (*Store, error) {
	if _, err := db.Exec(authSchema); err != nil {
		return nil, fmt.Errorf("migrating auth schema: %w", err)
	}
	return &Store{db: db}, nil
}

// ---- user CRUD ----

// CreateUser inserts a new user with a bcrypt-hashed password. Returns the
// populated User (without password_hash). The email is stored as-is but
// matched case-insensitively by SQLite COLLATE NOCASE.
func (s *Store) CreateUser(email, password, role string) (User, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcryptCost)
	if err != nil {
		return User{}, fmt.Errorf("hashing password: %w", err)
	}
	now := time.Now().UnixMilli()
	res, err := s.db.Exec(
		`INSERT INTO users (email, password_hash, role, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?)`,
		email, string(hash), role, now, now,
	)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return User{}, fmt.Errorf("email already registered")
		}
		return User{}, fmt.Errorf("inserting user: %w", err)
	}
	id, _ := res.LastInsertId()
	return User{ID: id, Email: email, Role: role, CreatedAt: now, UpdatedAt: now}, nil
}

// GetUserByEmail looks up a user by email (case-insensitive).
func (s *Store) GetUserByEmail(email string) (User, error) {
	var u User
	err := s.db.QueryRow(
		`SELECT id, email, password_hash, role, created_at, updated_at
		 FROM users WHERE email = ?`, email,
	).Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Role, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return User{}, fmt.Errorf("looking up user: %w", err)
	}
	return u, nil
}

// GetUserByID looks up a user by primary key.
func (s *Store) GetUserByID(id int64) (User, error) {
	var u User
	err := s.db.QueryRow(
		`SELECT id, email, password_hash, role, created_at, updated_at
		 FROM users WHERE id = ?`, id,
	).Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Role, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return User{}, fmt.Errorf("looking up user: %w", err)
	}
	return u, nil
}

// ListUsers returns all users ordered by creation time (newest first).
func (s *Store) ListUsers() ([]User, error) {
	rows, err := s.db.Query(
		`SELECT id, email, password_hash, role, created_at, updated_at
		 FROM users ORDER BY id DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("listing users: %w", err)
	}
	defer rows.Close()
	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Role, &u.CreatedAt, &u.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning user: %w", err)
		}
		users = append(users, u)
	}
	if users == nil {
		users = []User{}
	}
	return users, rows.Err()
}

// CountUsers returns the number of registered users.
func (s *Store) CountUsers() (int64, error) {
	var n int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting users: %w", err)
	}
	return n, nil
}

// DeleteUser removes a user by ID. Refresh tokens are cascade-deleted.
func (s *Store) DeleteUser(id int64) error {
	// Cascade may not be enforced by all SQLite builds; delete tokens explicitly.
	if _, err := s.db.Exec(`DELETE FROM refresh_tokens WHERE user_id = ?`, id); err != nil {
		return fmt.Errorf("deleting user refresh tokens: %w", err)
	}
	res, err := s.db.Exec(`DELETE FROM users WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("deleting user: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("user not found")
	}
	return nil
}

// ---- password verification ----

// CheckPassword compares a plaintext password against a bcrypt hash.
func CheckPassword(hash, password string) error {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
}

// ---- refresh token CRUD ----

// HashToken returns the hex-encoded SHA-256 of a raw token string.
func HashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

// InsertRefreshToken persists a hashed refresh token.
func (s *Store) InsertRefreshToken(userID int64, tokenHash string, expiresAt int64) error {
	now := time.Now().UnixMilli()
	_, err := s.db.Exec(
		`INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at)
		 VALUES (?, ?, ?, ?)`,
		userID, tokenHash, expiresAt, now,
	)
	if err != nil {
		return fmt.Errorf("inserting refresh token: %w", err)
	}
	return nil
}

// FindRefreshToken looks up a refresh token by its hash. Returns
// sql.ErrNoRows if not found.
func (s *Store) FindRefreshToken(tokenHash string) (RefreshToken, error) {
	var rt RefreshToken
	err := s.db.QueryRow(
		`SELECT id, user_id, token_hash, expires_at, created_at
		 FROM refresh_tokens WHERE token_hash = ?`, tokenHash,
	).Scan(&rt.ID, &rt.UserID, &rt.TokenHash, &rt.ExpiresAt, &rt.CreatedAt)
	if err != nil {
		return RefreshToken{}, err
	}
	return rt, nil
}

// DeleteRefreshToken removes a single refresh token by hash.
func (s *Store) DeleteRefreshToken(tokenHash string) error {
	_, err := s.db.Exec(`DELETE FROM refresh_tokens WHERE token_hash = ?`, tokenHash)
	return err
}

// DeleteUserRefreshTokens revokes all refresh tokens for a user (logout-all).
func (s *Store) DeleteUserRefreshTokens(userID int64) error {
	_, err := s.db.Exec(`DELETE FROM refresh_tokens WHERE user_id = ?`, userID)
	return err
}

// PurgeExpiredTokens removes all expired refresh tokens.
func (s *Store) PurgeExpiredTokens() (int64, error) {
	now := time.Now().UnixMilli()
	res, err := s.db.Exec(`DELETE FROM refresh_tokens WHERE expires_at < ?`, now)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// CountSignupsByIP counts the number of users created from a given IP within
// the specified window (milliseconds). Used for signup rate limiting.
// We track this via a separate lightweight table.
//
// NOTE: The signup_log table is created alongside the auth schema and stores
// only IP + timestamp — no PII beyond the IP address that is already in
// standard HTTP access logs.
