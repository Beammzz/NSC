"""SignMind AI — Python gRPC TSL inference service.

Modules:
  engine    — model loading/hot-swap, sliding-window prediction, runtime tuning
  server    — TslInference gRPC servicer (StreamInference / UploadModel /
              StreamLogs / GetTuning / SetTuning)
  logstream — logging handler with ring buffer + live subscribers for StreamLogs
  pb        — generated stubs from docs/api/tsl_inference.proto (never edit)
"""
