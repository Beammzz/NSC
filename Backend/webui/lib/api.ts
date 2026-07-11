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
  const resp = await fetch(url);
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
