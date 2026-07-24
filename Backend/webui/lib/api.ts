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
  auto_clean_max_predictions?: number;
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

export async function clearPredictions(): Promise<void> {
  let resp = await fetch('/api/v1/admin/predictions', { method: 'DELETE' });
  if (resp.status === 401) {
    const refreshed = await tryRefresh();
    if (refreshed) {
      resp = await fetch('/api/v1/admin/predictions', { method: 'DELETE' });
    }
  }
  if (!resp.ok) throw await asError(resp);
}

export async function putSettings(body: {
  confidence_threshold?: number;
  idle_min_frames_with_hands?: number;
  idle_motion_std_threshold?: number;
  auto_clean_max_predictions?: number;
}): Promise<Tuning & { auto_clean_max_predictions?: number }> {
  const resp = await fetch('/api/v1/admin/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as Tuning & { auto_clean_max_predictions?: number };
}

export const putTuning = putSettings;

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

// ---- Learning content API (admin) ----

export type LearnExercise = {
  id: number;
  topic_id: number;
  word: string;
  sort_order: number;
  pass_confidence: number;
  published: boolean;
};

export type LearnTopic = {
  id: number;
  slug: string;
  title: string;
  icon: string;
  sort_order: number;
  published: boolean;
  exercises: LearnExercise[];
};

export type LearnSign = {
  word: string;
  category: string;
  has_animation: boolean;
};

// One landmark of an avatar keypoint frame (raw normalized image coords 0..1).
export type KeypointFrame = { x: number; y: number; z: number };

// A dictionary entry with its recorded animation, from the per-word endpoint.
export type SignDetail = LearnSign & { keypoint_frames?: KeypointFrame[][] };

async function sendJSON<T>(method: string, url: string, body?: unknown): Promise<T> {
  const init = (): RequestInit => ({
    method,
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let resp = await fetch(url, init());
  if (resp.status === 401) {
    const refreshed = await tryRefresh();
    if (refreshed) {
      resp = await fetch(url, init());
    }
  }
  if (!resp.ok) throw await asError(resp);
  if (resp.status === 204) return undefined as T;
  return (await resp.json()) as T;
}

export function fetchLearnTopics(): Promise<LearnTopic[]> {
  return getJSON<{ topics: LearnTopic[] }>('/api/v1/admin/learn/topics').then((d) => d.topics);
}

export function fetchLearnSigns(): Promise<LearnSign[]> {
  return getJSON<{ signs: LearnSign[] }>('/api/v1/learn/dictionary').then((d) => d.signs);
}

export function createLearnTopic(
  body: Omit<LearnTopic, 'id' | 'exercises'>,
): Promise<LearnTopic> {
  return sendJSON<LearnTopic>('POST', '/api/v1/admin/learn/topics', body);
}

export function updateLearnTopic(
  id: number,
  body: Omit<LearnTopic, 'id' | 'exercises'>,
): Promise<LearnTopic> {
  return sendJSON<LearnTopic>('PUT', `/api/v1/admin/learn/topics/${id}`, body);
}

export function deleteLearnTopic(id: number): Promise<void> {
  return sendJSON<void>('DELETE', `/api/v1/admin/learn/topics/${id}`);
}

export function createLearnExercise(
  body: Omit<LearnExercise, 'id'>,
): Promise<LearnExercise> {
  return sendJSON<LearnExercise>('POST', '/api/v1/admin/learn/exercises', body);
}

export function updateLearnExercise(
  id: number,
  body: Omit<LearnExercise, 'id'>,
): Promise<LearnExercise> {
  return sendJSON<LearnExercise>('PUT', `/api/v1/admin/learn/exercises/${id}`, body);
}

export function deleteLearnExercise(id: number): Promise<void> {
  return sendJSON<void>('DELETE', `/api/v1/admin/learn/exercises/${id}`);
}

// ---- Dictionary sign admin API (admin) ----
// These build the recorded keypoint library the avatar plays back. fetch/create/
// delete go through sendJSON; the recording upload is multipart (webcam clip).

export function fetchAdminSigns(): Promise<LearnSign[]> {
  return getJSON<{ signs: LearnSign[] }>('/api/v1/admin/learn/signs').then((d) => d.signs);
}

// fetchSign returns one entry including its keypoint_frames animation (the
// per-word dictionary endpoint), used to preview the avatar in the admin UI.
export function fetchSign(word: string): Promise<SignDetail> {
  return getJSON<SignDetail>(`/api/v1/learn/dictionary/${encodeURIComponent(word)}`);
}

export function createSign(word: string, category: string): Promise<{ word: string; category: string }> {
  return sendJSON<{ word: string; category: string }>('POST', '/api/v1/admin/learn/signs', {
    word,
    category,
  });
}

export function deleteSign(word: string): Promise<void> {
  return sendJSON<void>('DELETE', `/api/v1/admin/learn/signs/${encodeURIComponent(word)}`);
}

// uploadSignRecording POSTs a recorded clip as multipart (field "recording");
// the Go server execs the Python extractor and stores the keypoint frames. The
// FormData is rebuilt per attempt so the one 401 refresh-retry can resend it.
export async function uploadSignRecording(
  word: string,
  clip: Blob,
  ext: string,
): Promise<{ word: string; has_animation: boolean }> {
  const url = `/api/v1/admin/learn/signs/${encodeURIComponent(word)}/recording`;
  const send = () => {
    const fd = new FormData();
    fd.append('recording', clip, `recording.${ext}`);
    return fetch(url, { method: 'POST', body: fd });
  };
  let resp = await send();
  if (resp.status === 401) {
    const refreshed = await tryRefresh();
    if (refreshed) resp = await send();
  }
  if (!resp.ok) throw await asError(resp);
  return (await resp.json()) as { word: string; has_animation: boolean };
}

export function importSignFromThsl(
  url: string,
  word?: string,
  category?: string,
): Promise<{ word: string; category: string; has_animation: boolean; source_url: string; video_url: string }> {
  return sendJSON<{ word: string; category: string; has_animation: boolean; source_url: string; video_url: string }>(
    'POST',
    '/api/v1/admin/learn/signs/import-thsl',
    { url, word, category },
  );
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

// ---- Dictionary Reindexing & Idle Detection ----

export function isIdleWord(word?: string, isIdleFlag?: boolean): boolean {
  if (isIdleFlag) return true;
  if (!word) return true;
  const w = word.trim().toLowerCase();
  return w === 'ไม่ทำอะไรเลย' || w === 'ไม่ทำไรเลย' || w === 'idle' || w.includes('idle');
}

export const DEFAULT_LABEL_MAP_VOCABULARY: Record<string, string> = {
  '1': 'ตัวเลข',
  '10': 'ตัวเลข',
  '100': 'ตัวเลข',
  '2': 'ตัวเลข',
  '3': 'ตัวเลข',
  '30': 'ตัวเลข',
  '4': 'ตัวเลข',
  '5': 'ตัวเลข',
  '6': 'ตัวเลข',
  '7': 'ตัวเลข',
  '8': 'ตัวเลข',
  '9': 'ตัวเลข',
  กบ: 'สัตว์และธรรมชาติ',
  กรกฎาคม: 'วันและเดือน',
  กรรไกร: 'สิ่งของและสถานที่',
  กระจก: 'สิ่งของและสถานที่',
  กระดาษ: 'สิ่งของและสถานที่',
  กระโดด: 'กิจวัตรและการกระทำ',
  กลับ: 'กิจวัตรและการกระทำ',
  กลับบ้าน: 'กิจวัตรและการกระทำ',
  กล้วย: 'อาหารและเครื่องดื่ม',
  กังวล: 'อารมณ์ความรู้สึก',
  กันยายน: 'วันและเดือน',
  กาแฟ: 'อาหารและเครื่องดื่ม',
  กำลัง: 'คำพื้นฐาน',
  กิน: 'กิจวัตรและการกระทำ',
  กุญแจ: 'สิ่งของและสถานที่',
  กุมภาพันธ์: 'วันและเดือน',
  กุ้ง: 'อาหารและเครื่องดื่ม',
  ก่อน: 'เวลา',
  ขอ: 'คำพื้นฐาน',
  ของคุณ: 'ผู้คนและครอบครัว',
  ของฉัน: 'ผู้คนและครอบครัว',
  ขอบคุณ: 'คำพื้นฐาน',
  ขอโทษ: 'คำพื้นฐาน',
  ขับรถ: 'กิจวัตรและการกระทำ',
  ขาย: 'กิจวัตรและการกระทำ',
  ข้าว: 'อาหารและเครื่องดื่ม',
  คิด: 'อารมณ์ความรู้สึก',
  คิ้ว: 'ร่างกาย',
  คุณ: 'ผู้คนและครอบครัว',
  ง่วง: 'อารมณ์ความรู้สึก',
  จมูก: 'ร่างกาย',
  ฉัน: 'ผู้คนและครอบครัว',
  ชนะ: 'คำพื้นฐาน',
  ชอบ: 'อารมณ์ความรู้สึก',
  ชา: 'อาหารและเครื่องดื่ม',
  ชื่อ: 'คำพื้นฐาน',
  ช่วย: 'คำพื้นฐาน',
  ช้า: 'คำพื้นฐาน',
  ซื้อ: 'กิจวัตรและการกระทำ',
  ซ้ำ: 'คำพื้นฐาน',
  ดี: 'คำพื้นฐาน',
  ดีใจ: 'อารมณ์ความรู้สึก',
  ดื่ม: 'กิจวัตรและการกระทำ',
  ดู: 'กิจวัตรและการกระทำ',
  คฺุณ: 'ผู้คนและครอบครัว',
  ตลาด: 'สิ่งของและสถานที่',
  ตา: 'ร่างกาย',
  ตุลาคม: 'วันและเดือน',
  ตู้เสื้อผ้า: 'สิ่งของและสถานที่',
  ถนน: 'สิ่งของและสถานที่',
  ถึง: 'กิจวัตรและการกระทำ',
  ถุงเท้า: 'สิ่งของและสถานที่',
  ถูก: 'คำพื้นฐาน',
  ถ่ายรูป: 'กิจวัตรและการกระทำ',
  ทราย: 'สัตว์และธรรมชาติ',
  ทะเล: 'สัตว์และธรรมชาติ',
  ทะเลาะ: 'อารมณ์ความรู้สึก',
  ทำงาน: 'กิจวัตรและการกระทำ',
  ที่ไหน: 'คำถามและประโยค',
  ธันวาคม: 'วันและเดือน',
  นก: 'สัตว์และธรรมชาติ',
  นม: 'อาหารและเครื่องดื่ม',
  นอน: 'กิจวัตรและการกระทำ',
  นั่ง: 'กิจวัตรและการกระทำ',
  นามสกุล: 'คำพื้นฐาน',
  นิ้ว: 'ร่างกาย',
  น้อง: 'ผู้คนและครอบครัว',
  น้อย: 'คำพื้นฐาน',
  น้ำ: 'อาหารและเครื่องดื่ม',
  บ้าน: 'สิ่งของและสถานที่',
  บ๊ายบาย: 'คำพื้นฐาน',
  ประตู: 'สิ่งของและสถานที่',
  ปลา: 'สัตว์และธรรมชาติ',
  ปาก: 'ร่างกาย',
  ปากกา: 'สิ่งของและสถานที่',
  ปิด: 'กิจวัตรและการกระทำ',
  ปี: 'เวลา',
  ปู: 'สัตว์และธรรมชาติ',
  ผม: 'ผู้คนและครอบครัว',
  ผลไม้: 'อาหารและเครื่องดื่ม',
  ฝนตก: 'สัตว์และธรรมชาติ',
  ฝันดี: 'คำพื้นฐาน',
  พรุ่งนี้: 'เวลา',
  พร้อม: 'คำพื้นฐาน',
  พฤศจิกายน: 'วันและเดือน',
  พฤษภาคม: 'วันและเดือน',
  พี่: 'ผู้คนและครอบครัว',
  พูด: 'กิจวัตรและการกระทำ',
  พ่อ: 'ผู้คนและครอบครัว',
  พ่อค้า: 'ผู้คนและครอบครัว',
  ฟัง: 'กิจวัตรและการกระทำ',
  มกราคม: 'วันและเดือน',
  มะม่วง: 'อาหารและเครื่องดื่ม',
  มา: 'กิจวัตรและการกระทำ',
  มาก: 'คำพื้นฐาน',
  มิถุนายน: 'วันและเดือน',
  มี: 'คำพื้นฐาน',
  มีนาคม: 'วันและเดือน',
  มือ: 'ร่างกาย',
  ยืน: 'กิจวัตรและการกระทำ',
  ยืม: 'กิจวัตรและการกระทำ',
  ยุ่ง: 'อารมณ์ความรู้สึก',
  รองเท้า: 'สิ่งของและสถานที่',
  ระวัง: 'คำพื้นฐาน',
  รัก: 'อารมณ์ความรู้สึก',
  ราคา: 'สิ่งของและสถานที่',
  ลด: 'คำพื้นฐาน',
  ลม: 'สัตว์และธรรมชาติ',
  ล้าง: 'กิจวัตรและการกระทำ',
  วันจันทร์: 'วันและเดือน',
  วันนี้: 'เวลา',
  วันพฤหัสบดี: 'วันและเดือน',
  วันพุธ: 'วันและเดือน',
  วันศุกร์: 'วันและเดือน',
  วันอังคาร: 'วันและเดือน',
  วันอาทิตย์: 'วันและเดือน',
  วันเสาร์: 'วันและเดือน',
  วิ่ง: 'กิจวัตรและการกระทำ',
  สบาย: 'คำพื้นฐาน',
  สบายดี: 'คำพื้นฐาน',
  สวัสดี: 'คำพื้นฐาน',
  สอน: 'กิจวัตรและการกระทำ',
  สะพาน: 'สิ่งของและสถานที่',
  สิงหาคม: 'วันและเดือน',
  สี: 'สี',
  สีชมพู: 'สี',
  สีดำ: 'สี',
  สีฟ้า: 'สี',
  สีม่วง: 'สี',
  สีเขียว: 'สี',
  สีแดง: 'สี',
  ส่ง: 'กิจวัตรและการกระทำ',
  ส้ม: 'อาหารและเครื่องดื่ม',
  หนังสือ: 'สิ่งของและสถานที่',
  หนาว: 'อารมณ์ความรู้สึก',
  หมด: 'คำพื้นฐาน',
  หมวก: 'สิ่งของและสถานที่',
  หิน: 'สัตว์และธรรมชาติ',
  หิว: 'อารมณ์ความรู้สึก',
  หู: 'ร่างกาย',
  ห้องครัว: 'สิ่งของและสถานที่',
  ห้องน้ำ: 'สิ่งของและสถานที่',
  อธิบาย: 'กิจวัตรและการกระทำ',
  อยาก: 'อารมณ์ความรู้สึก',
  อยู่: 'กิจวัตรและการกระทำ',
  อย่างไร: 'คำถามและประโยค',
  อร่อย: 'อาหารและเครื่องดื่ม',
  อะไร: 'คำถามและประโยค',
  อากาศ: 'สัตว์และธรรมชาติ',
  อาบน้ำ: 'กิจวัตรและการกระทำ',
  อีก: 'คำพื้นฐาน',
  อ่าน: 'กิจวัตรและการกระทำ',
  เกม: 'สิ่งของและสถานที่',
  เกลียด: "อารมณ์ความรู้สึก",
  เขียน: 'กิจวัตรและการกระทำ',
  เข้าใจ: 'อารมณ์ความรู้สึก',
  เครียด: 'อารมณ์ความรู้สึก',
  เค้ก: 'อาหารและเครื่องดื่ม',
  เจอ: 'กิจวัตรและการกระทำ',
  เช้า: 'เวลา',
  เดิน: 'กิจวัตรและการกระทำ',
  เดือน: 'เวลา',
  เบื่อ: 'อารมณ์ความรู้สึก',
  เปิด: 'กิจวัตรและการกระทำ',
  เปิดไฟ: 'กิจวัตรและการกระทำ',
  เป็น: 'คำพื้นฐาน',
  เผ็ด: 'อาหารและเครื่องดื่ม',
  เพลง: 'สิ่งของและสถานที่',
  เมษายน: 'วันและเดือน',
  เมื่อวาน: 'เวลา',
  เมื่อวานซืน: 'เวลา',
  เรา: 'ผู้คนและครอบครัว',
  เรียน: 'กิจวัตรและการกระทำ',
  เร็ว: 'คำพื้นฐาน',
  เล่น: 'กิจวัตรและการกระทำ',
  เวลา: 'เวลา',
  เสร็จ: 'คำพื้นฐาน',
  เสื้อ: 'สิ่งของและสถานที่',
  เหนื่อย: 'อารมณ์ความรู้สึก',
  เอา: 'คำพื้นฐาน',
  เเล้ว: 'คำพื้นฐาน',
  แก้ม: 'ร่างกาย',
  แตงโม: 'อาหารและเครื่องดื่ม',
  แปรงฟัน: 'กิจวัตรและการกระทำ',
  แพง: 'คำพื้นฐาน',
  แม่: 'ผู้คนและครอบครัว',
  แย่: 'คำพื้นฐาน',
  แว่น: 'สิ่งของและสถานที่',
  แอปเปิ้ล: 'อาหารและเครื่องดื่ม',
  โชคดี: 'คำพื้นฐาน',
  โต๊ะ: 'สิ่งของและสถานที่',
  โทร: 'กิจวัตรและการกระทำ',
  โรงเรียน: 'สิ่งของและสถานที่',
  โอเค: 'คำพื้นฐาน',
  ใช่: 'คำพื้นฐาน',
  ใช้ได้: 'คำพื้นฐาน',
  ไก่: 'สัตว์และธรรมชาติ',
  ไก่ทอด: 'อาหารและเครื่องดื่ม',
  ไข่: 'อาหารและเครื่องดื่ม',
  ได้ยิน: 'กิจวัตรและการกระทำ',
  ได้รับ: 'กิจวัตรและการกระทำ',
  ไป: 'กิจวัตรและการกระทำ',
  ไปเที่ยว: 'กิจวัตรและการกระทำ',
  ไม่: 'คำพื้นฐาน',
  ไม่เข้าใจ: 'คำพื้นฐาน',
  ไม่เป็นไร: 'คำพื้นฐาน',
};

export async function reindexDictionaryFromLabelMap(
  customVocabulary?: Record<string, string>,
): Promise<{ total: number; added: number }> {
  const existing = await fetchAdminSigns();
  const existingWords = new Set(existing.map((s) => s.word.trim()));
  const targetMap = customVocabulary || DEFAULT_LABEL_MAP_VOCABULARY;

  let added = 0;
  let total = 0;

  for (const [wordRaw, category] of Object.entries(targetMap)) {
    const word = wordRaw.trim();
    if (isIdleWord(word)) continue; // Never index "ไม่ทำอะไรเลย" / idle
    total++;
    if (!existingWords.has(word)) {
      try {
        await createSign(word, category || 'ทั่วไป');
        existingWords.add(word);
        added++;
      } catch (err) {
        console.warn(`Failed to index sign ${word}:`, err);
      }
    }
  }

  return { total, added };
}


