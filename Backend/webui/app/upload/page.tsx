'use client';

import { useState } from 'react';
import { UploadResult } from '../../lib/api';

export default function UploadModelPage() {
  const [modelFile, setModelFile] = useState<File | null>(null);
  const [labelMapFile, setLabelMapFile] = useState<File | null>(null);
  const [preprocessFile, setPreprocessFile] = useState<File | null>(null);

  const [uploading, setUploading] = useState<boolean>(false);
  const [progress, setProgress] = useState<number>(0);
  const [result, setResult] = useState<UploadResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  function handleUploadSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!modelFile || !labelMapFile) {
      setError('Both model (.tflite) and label_map (.json) are required.');
      return;
    }

    setUploading(true);
    setProgress(0);
    setResult(null);
    setError(null);

    const fd = new FormData();
    fd.append('model', modelFile);
    fd.append('label_map', labelMapFile);
    if (preprocessFile) {
      fd.append('preprocess_config', preprocessFile);
    }

    uploadFormData('/api/v1/admin/model', fd, (pctVal) => {
      setProgress(pctVal);
    })
      .then((resData) => {
        setResult(resData);
      })
      .catch((err) => {
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        setUploading(false);
      });
  }

  return (
    <div>
      <h1>Upload Model</h1>
      <p className="subtitle">Hot-swap active TSL recognition model artifacts in the Python inference worker</p>

      <div className="card" style={{ maxWidth: '620px' }}>
        <form onSubmit={handleUploadSubmit}>
          <label className="field">
            <span>Model File (.tflite) * Required</span>
            <input
              type="file"
              accept=".tflite"
              required
              onChange={(e) => setModelFile(e.target.files?.[0] ?? null)}
            />
          </label>

          <label className="field">
            <span>Label Map (.json) * Required</span>
            <input
              type="file"
              accept=".json"
              required
              onChange={(e) => setLabelMapFile(e.target.files?.[0] ?? null)}
            />
          </label>

          <label className="field">
            <span>Preprocess Config (.json) Optional</span>
            <input
              type="file"
              accept=".json"
              onChange={(e) => setPreprocessFile(e.target.files?.[0] ?? null)}
            />
          </label>

          {uploading && (
            <div style={{ margin: '14px 0' }}>
              <div style={{ fontSize: '12px', color: 'var(--text-secondary)', marginBottom: '4px' }}>
                Uploading artifacts... ({progress}%)
              </div>
              <progress value={progress} max={100} />
            </div>
          )}

          {error && (
            <div className="notice error">
              Upload rejected: {error}
            </div>
          )}

          {result && (
            <div className="notice success">
              <strong>Model hot-swapped successfully!</strong>
              <div style={{ marginTop: '6px' }}>
                Num Classes: {result.num_classes} &nbsp;|&nbsp; Sequence Len: {result.sequence_len} &nbsp;|&nbsp; Feature Dim: {result.feature_dim}
              </div>
            </div>
          )}

          <div style={{ marginTop: '16px' }}>
            <button type="submit" disabled={uploading || !modelFile || !labelMapFile}>
              {uploading ? 'Uploading...' : 'Upload & Deploy Model'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function uploadFormData(
  url: string,
  formData: FormData,
  onProgress: (pct: number) => void
): Promise<UploadResult> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        const percent = Math.round((event.loaded / event.total) * 100);
        onProgress(percent);
      }
    };

    xhr.onload = () => {
      let data: any;
      try {
        data = JSON.parse(xhr.responseText);
      } catch {
        data = null;
      }

      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(data as UploadResult);
      } else {
        let msg = `HTTP ${xhr.status}`;
        if (data && typeof data === 'object') {
          if (data.title) msg = data.title;
          if (data.detail) msg += `: ${data.detail}`;
        } else if (xhr.responseText) {
          msg = xhr.responseText;
        }
        reject(new Error(msg));
      }
    };

    xhr.onerror = () => {
      reject(new Error('Network error occurred during file upload.'));
    };

    xhr.send(formData);
  });
}
