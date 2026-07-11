# TSL_Output — model artifacts

Drop the trained artifacts (recovered from the training repo) directly here:

- `tsl_lstm_f32.tflite` — the LSTM model (LiteRT/TFLite flatbuffer)
- `label_map.json` — `{"label": index, ...}`, 150 classes
- `preprocess_config.json` — training-time preprocessing flags/threshold
  (without it the engine falls back to defaults and predictions cannot be
  trusted for accuracy)

The inference server auto-loads them at startup. Alternatively upload a model
at runtime via the `UploadModel` RPC — uploads land in `uploads/<utc-ts>/`
and `active_model.json` points at the active set (it wins over loose files
here when present).
