package auth

import (
	"database/sql"
	"testing"

	_ "modernc.org/sqlite"
)

func testDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:?_pragma=journal_mode(WAL)")
	if err != nil {
		t.Fatalf("opening in-memory db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func testStore(t *testing.T) *Store {
	t.Helper()
	db := testDB(t)
	s, err := OpenStore(db)
	if err != nil {
		t.Fatalf("opening auth store: %v", err)
	}
	return s
}

func TestCreateAndGetUser(t *testing.T) {
	s := testStore(t)

	u, err := s.CreateUser("Admin@example.com", "Password1", RoleAdmin)
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	if u.ID == 0 {
		t.Fatal("expected non-zero user ID")
	}
	if u.Email != "Admin@example.com" {
		t.Fatalf("expected email preserved, got %q", u.Email)
	}
	if u.Role != RoleAdmin {
		t.Fatalf("expected role %q, got %q", RoleAdmin, u.Role)
	}

	// Lookup by email (case-insensitive).
	got, err := s.GetUserByEmail("admin@example.com")
	if err != nil {
		t.Fatalf("GetUserByEmail: %v", err)
	}
	if got.ID != u.ID {
		t.Fatalf("expected ID %d, got %d", u.ID, got.ID)
	}
	if got.PasswordHash == "" {
		t.Fatal("expected password hash to be populated")
	}

	// Lookup by ID.
	got2, err := s.GetUserByID(u.ID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}
	if got2.Email != u.Email {
		t.Fatalf("expected email %q, got %q", u.Email, got2.Email)
	}
}

func TestDuplicateEmail(t *testing.T) {
	s := testStore(t)

	_, err := s.CreateUser("dup@example.com", "Password1", RoleUser)
	if err != nil {
		t.Fatalf("first CreateUser: %v", err)
	}
	_, err = s.CreateUser("DUP@example.com", "Password2", RoleUser)
	if err == nil {
		t.Fatal("expected duplicate email error")
	}
}

func TestListUsers(t *testing.T) {
	s := testStore(t)

	_, _ = s.CreateUser("a@example.com", "Password1", RoleAdmin)
	_, _ = s.CreateUser("b@example.com", "Password2", RoleUser)

	users, err := s.ListUsers()
	if err != nil {
		t.Fatalf("ListUsers: %v", err)
	}
	if len(users) != 2 {
		t.Fatalf("expected 2 users, got %d", len(users))
	}
	// Newest first.
	if users[0].Email != "b@example.com" {
		t.Fatalf("expected newest first, got %q", users[0].Email)
	}
}

func TestDeleteUser(t *testing.T) {
	s := testStore(t)

	u, _ := s.CreateUser("del@example.com", "Password1", RoleUser)
	if err := s.DeleteUser(u.ID); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}
	if err := s.DeleteUser(u.ID); err == nil {
		t.Fatal("expected error deleting non-existent user")
	}
}

func TestCheckPassword(t *testing.T) {
	s := testStore(t)

	_, err := s.CreateUser("pw@example.com", "Correct1", RoleUser)
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	u, _ := s.GetUserByEmail("pw@example.com")

	if err := CheckPassword(u.PasswordHash, "Correct1"); err != nil {
		t.Fatalf("expected password to match: %v", err)
	}
	if err := CheckPassword(u.PasswordHash, "Wrong1234"); err == nil {
		t.Fatal("expected wrong password to fail")
	}
}

func TestRefreshTokenLifecycle(t *testing.T) {
	s := testStore(t)

	u, _ := s.CreateUser("rt@example.com", "Password1", RoleUser)
	rawToken := "test-refresh-token-value"
	tokenHash := HashToken(rawToken)
	expiresAt := int64(9999999999999)

	if err := s.InsertRefreshToken(u.ID, tokenHash, expiresAt); err != nil {
		t.Fatalf("InsertRefreshToken: %v", err)
	}

	rt, err := s.FindRefreshToken(tokenHash)
	if err != nil {
		t.Fatalf("FindRefreshToken: %v", err)
	}
	if rt.UserID != u.ID {
		t.Fatalf("expected user ID %d, got %d", u.ID, rt.UserID)
	}

	// Delete.
	if err := s.DeleteRefreshToken(tokenHash); err != nil {
		t.Fatalf("DeleteRefreshToken: %v", err)
	}
	_, err = s.FindRefreshToken(tokenHash)
	if err == nil {
		t.Fatal("expected token to be deleted")
	}
}

func TestDeleteUserCascadesRefreshTokens(t *testing.T) {
	s := testStore(t)

	u, _ := s.CreateUser("cascade@example.com", "Password1", RoleUser)
	_ = s.InsertRefreshToken(u.ID, HashToken("tok1"), 9999999999999)
	_ = s.InsertRefreshToken(u.ID, HashToken("tok2"), 9999999999999)

	if err := s.DeleteUser(u.ID); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}

	// Both tokens should be gone.
	_, err := s.FindRefreshToken(HashToken("tok1"))
	if err == nil {
		t.Fatal("expected token to be cascade-deleted")
	}
}

func TestCountUsers(t *testing.T) {
	s := testStore(t)

	n, err := s.CountUsers()
	if err != nil {
		t.Fatalf("CountUsers: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 users, got %d", n)
	}

	_, _ = s.CreateUser("count@example.com", "Password1", RoleUser)
	n, _ = s.CountUsers()
	if n != 1 {
		t.Fatalf("expected 1 user, got %d", n)
	}
}
