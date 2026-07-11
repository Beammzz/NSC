'use client';

import { useEffect, useState, FormEvent } from 'react';
import { fetchUsers, createUser, deleteUser, UserRecord, formatTime } from '../../lib/api';

export default function UsersPage() {
  const [users, setUsers] = useState<UserRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Create user form state.
  const [showForm, setShowForm] = useState(false);
  const [newEmail, setNewEmail] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [newRole, setNewRole] = useState('user');
  const [creating, setCreating] = useState(false);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  // Delete confirmation state.
  const [confirmDelete, setConfirmDelete] = useState<number | null>(null);

  async function loadUsers() {
    try {
      const data = await fetchUsers();
      setUsers(data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadUsers();
  }, []);

  async function handleCreate(e: FormEvent) {
    e.preventDefault();
    setCreating(true);
    setNotice(null);
    try {
      await createUser(newEmail, newPassword, newRole);
      setNotice({ type: 'success', text: `User ${newEmail} created successfully.` });
      setNewEmail('');
      setNewPassword('');
      setNewRole('user');
      setShowForm(false);
      await loadUsers();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to create user: ${msg}` });
    } finally {
      setCreating(false);
    }
  }

  async function handleDelete(id: number) {
    try {
      await deleteUser(id);
      setNotice({ type: 'success', text: 'User deleted.' });
      setConfirmDelete(null);
      await loadUsers();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to delete user: ${msg}` });
      setConfirmDelete(null);
    }
  }

  return (
    <div>
      <h1>Users</h1>
      <p className="subtitle">Manage user accounts and access roles</p>

      {notice && (
        <div className={`notice ${notice.type}`}>{notice.text}</div>
      )}

      {error && (
        <div className="notice error">Failed to load users: {error}</div>
      )}

      <div className="row" style={{ marginBottom: 16 }}>
        <button id="create-user-btn" onClick={() => setShowForm(!showForm)}>
          {showForm ? 'Cancel' : '+ Create User'}
        </button>
        <span className="chip info">
          <span className="dot" />
          {users.length} user{users.length !== 1 ? 's' : ''}
        </span>
      </div>

      {showForm && (
        <div className="card" style={{ marginBottom: 20 }}>
          <h2>New User</h2>
          <form onSubmit={handleCreate}>
            <label className="field">
              <span>Email</span>
              <input
                id="new-user-email"
                type="email"
                value={newEmail}
                onChange={(e) => setNewEmail(e.target.value)}
                placeholder="user@example.com"
                required
              />
            </label>
            <label className="field">
              <span>Password (min 8 chars, 1 upper, 1 lower, 1 digit)</span>
              <input
                id="new-user-password"
                type="password"
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
                placeholder="••••••••"
                required
                minLength={8}
              />
            </label>
            <label className="field">
              <span>Role</span>
              <select
                id="new-user-role"
                value={newRole}
                onChange={(e) => setNewRole(e.target.value)}
              >
                <option value="user">User</option>
                <option value="admin">Admin</option>
              </select>
            </label>
            <button id="create-user-submit" type="submit" disabled={creating}>
              {creating ? 'Creating...' : 'Create User'}
            </button>
          </form>
        </div>
      )}

      {loading ? (
        <div className="empty">Loading users...</div>
      ) : users.length === 0 ? (
        <div className="empty">No users found.</div>
      ) : (
        <div className="tablewrap">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Email</th>
                <th>Role</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {users.map((u) => (
                <tr key={u.id}>
                  <td>{u.id}</td>
                  <td className="word">{u.email}</td>
                  <td>
                    <span className={`chip ${u.role === 'admin' ? 'warning' : 'info'}`}>
                      <span className="dot" />
                      {u.role}
                    </span>
                  </td>
                  <td>{formatTime(u.created_at)}</td>
                  <td>
                    {confirmDelete === u.id ? (
                      <span className="row" style={{ gap: 6 }}>
                        <button
                          className="secondary"
                          style={{ fontSize: 12, padding: '4px 10px' }}
                          onClick={() => handleDelete(u.id)}
                        >
                          Confirm
                        </button>
                        <button
                          className="secondary"
                          style={{ fontSize: 12, padding: '4px 10px' }}
                          onClick={() => setConfirmDelete(null)}
                        >
                          Cancel
                        </button>
                      </span>
                    ) : (
                      <button
                        className="secondary"
                        style={{ fontSize: 12, padding: '4px 10px' }}
                        onClick={() => setConfirmDelete(u.id)}
                      >
                        Delete
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
