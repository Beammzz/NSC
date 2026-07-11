// Typed client for the Go admin REST API (/api/v1/admin/*). The webui is
// served by the same Go server, so all paths are same-origin relative.

export type Tuning = {
  confidence_threshold: number;
  idle_min_frames_with_hands: number;
  idle_motion_std_threshold: number;
  debug_mode: boolean;
  model_loaded: boolean;
  num_classes: number;
  sequence_len: number;
  feature_dim: number;
};

export type Status = {
  env: string;
  debug: boolean;
  ai_online: boolean;
  ai_error?: string;
  tuning?: Tuning;
  predictions_total: number;
};

export type ClassProb = { label: string; prob: number };

export type PredictionRecord = {
  id: number;
  created_ms: number;
  seq: number;
  word: string;
  confidence: number;
  is_idle: boolean;
  is_uncertain: boolean;
  inference_micros: number;
  other_prob: number;
  top: ClassProb[];
};

export type PredictionsPage = { total: number; records: PredictionRecord[] };

export type UploadResult = {
  reloaded: boolean;
  num_classes: number;
  sequence_len: number;
  feature_dim: number;
};

// ---- Auth types ----

export type AuthUser = {
  id: number;
  email: string;
  role: string;
};

export type AuthResponse = {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  user: AuthUser;
};

export type UserRecord = {
  id: number;
  email: string;
  role: string;
  created_at: number;
  updated_at: number;
};

// RFC 7807 problem body returned by the Go server on errors.
type Problem = { title?: string; detail?: string };

async function asError(resp: Response): Promise<Error> {
  let message = `HTTP ${resp.status}`;
  try {
    const problem = (await resp.json()) as Problem;
    if (problem.title) message = problem.title;
    if (problem.detail) message += `: ${problem.detail}`;
  } catch {
    /* non-JSON error body; keep the status line */
  }
  return new Error(message);
}

async function getJSON<T>(url: string): Promise<T> {
  let resp = await fetch(url);
  if (resp.status === 401) {
    // Attempt one silent refresh, then retry.
    const refreshed = await tryRefresh();
    if (refreshed) {
      resp = await fetch(url);
    }
  }
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as T;
}

async function postJSON<T>(url: string, body: unknown): Promise<T> {
  let resp = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (resp.status === 401) {
    const refreshed = await tryRefresh();
    if (refreshed) {
      resp = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
    }
  }
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as T;
}

export function fetchStatus(): Promise<Status> {
  return getJSON<Status>('/api/v1/admin/status');
}

export function fetchPredictions(params: {
  word?: string;
  limit?: number;
  offset?: number;
}): Promise<PredictionsPage> {
  const q = new URLSearchParams();
  if (params.word) q.set('word', params.word);
  if (params.limit !== undefined) q.set('limit', String(params.limit));
  if (params.offset) q.set('offset', String(params.offset));
  const qs = q.toString();
  return getJSON<PredictionsPage>(`/api/v1/admin/predictions${qs ? `?${qs}` : ''}`);
}

export async function putTuning(body: {
  confidence_threshold?: number;
  idle_min_frames_with_hands?: number;
  idle_motion_std_threshold?: number;
}): Promise<Tuning> {
  const resp = await fetch('/api/v1/admin/tuning', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as Tuning;
}

export function formatTime(ms: number): string {
  return new Date(ms).toLocaleTimeString(undefined, { hour12: false });
}

export function pct(p: number): string {
  return `${(p * 100).toFixed(1)}%`;
}

// ---- Auth API ----

export async function login(email: string, password: string): Promise<AuthResponse> {
  const resp = await fetch('/api/v1/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as AuthResponse;
}

export async function signup(email: string, password: string): Promise<AuthResponse> {
  const resp = await fetch('/api/v1/auth/signup', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as AuthResponse;
}

export async function logout(): Promise<void> {
  await fetch('/api/v1/auth/logout', { method: 'POST' });
}

export async function fetchMe(): Promise<AuthUser> {
  const resp = await fetch('/api/v1/auth/me');
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as AuthUser;
}

async function tryRefresh(): Promise<boolean> {
  try {
    const resp = await fetch('/api/v1/auth/refresh', { method: 'POST' });
    return resp.ok;
  } catch {
    return false;
  }
}

// ---- User Management API (admin) ----

export async function fetchUsers(): Promise<UserRecord[]> {
  const data = await getJSON<{ users: UserRecord[] }>('/api/v1/admin/users');
  return data.users;
}

export async function createUser(
  email: string,
  password: string,
  role: string,
): Promise<UserRecord> {
  return postJSON<UserRecord>('/api/v1/admin/users', { email, password, role });
}

export async function deleteUser(id: number): Promise<void> {
  let resp = await fetch(`/api/v1/admin/users/${id}`, { method: 'DELETE' });
  if (resp.status === 401) {
    const refreshed = await tryRefresh();
    if (refreshed) {
      resp = await fetch(`/api/v1/admin/users/${id}`, { method: 'DELETE' });
    }
  }
  if (!resp.ok) throw await asError(resp);
}

