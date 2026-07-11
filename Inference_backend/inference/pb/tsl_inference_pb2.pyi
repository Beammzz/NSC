from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class FileKind(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    FILE_KIND_UNSPECIFIED: _ClassVar[FileKind]
    FILE_KIND_TFLITE_MODEL: _ClassVar[FileKind]
    FILE_KIND_LABEL_MAP: _ClassVar[FileKind]
    FILE_KIND_PREPROCESS_CONFIG: _ClassVar[FileKind]

class LogLevel(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    LOG_LEVEL_UNSPECIFIED: _ClassVar[LogLevel]
    LOG_LEVEL_DEBUG: _ClassVar[LogLevel]
    LOG_LEVEL_INFO: _ClassVar[LogLevel]
    LOG_LEVEL_WARNING: _ClassVar[LogLevel]
    LOG_LEVEL_ERROR: _ClassVar[LogLevel]
FILE_KIND_UNSPECIFIED: FileKind
FILE_KIND_TFLITE_MODEL: FileKind
FILE_KIND_LABEL_MAP: FileKind
FILE_KIND_PREPROCESS_CONFIG: FileKind
LOG_LEVEL_UNSPECIFIED: LogLevel
LOG_LEVEL_DEBUG: LogLevel
LOG_LEVEL_INFO: LogLevel
LOG_LEVEL_WARNING: LogLevel
LOG_LEVEL_ERROR: LogLevel

class LandmarkFrame(_message.Message):
    __slots__ = ("seq", "timestamp_ms", "features", "reset")
    SEQ_FIELD_NUMBER: _ClassVar[int]
    TIMESTAMP_MS_FIELD_NUMBER: _ClassVar[int]
    FEATURES_FIELD_NUMBER: _ClassVar[int]
    RESET_FIELD_NUMBER: _ClassVar[int]
    seq: int
    timestamp_ms: int
    features: _containers.RepeatedScalarFieldContainer[float]
    reset: bool
    def __init__(self, seq: _Optional[int] = ..., timestamp_ms: _Optional[int] = ..., features: _Optional[_Iterable[float]] = ..., reset: _Optional[bool] = ...) -> None: ...

class Prediction(_message.Message):
    __slots__ = ("seq", "word", "confidence", "is_idle", "is_uncertain", "top", "inference_micros")
    SEQ_FIELD_NUMBER: _ClassVar[int]
    WORD_FIELD_NUMBER: _ClassVar[int]
    CONFIDENCE_FIELD_NUMBER: _ClassVar[int]
    IS_IDLE_FIELD_NUMBER: _ClassVar[int]
    IS_UNCERTAIN_FIELD_NUMBER: _ClassVar[int]
    TOP_FIELD_NUMBER: _ClassVar[int]
    INFERENCE_MICROS_FIELD_NUMBER: _ClassVar[int]
    seq: int
    word: str
    confidence: float
    is_idle: bool
    is_uncertain: bool
    top: _containers.RepeatedCompositeFieldContainer[ClassProb]
    inference_micros: int
    def __init__(self, seq: _Optional[int] = ..., word: _Optional[str] = ..., confidence: _Optional[float] = ..., is_idle: _Optional[bool] = ..., is_uncertain: _Optional[bool] = ..., top: _Optional[_Iterable[_Union[ClassProb, _Mapping]]] = ..., inference_micros: _Optional[int] = ...) -> None: ...

class ClassProb(_message.Message):
    __slots__ = ("label", "prob")
    LABEL_FIELD_NUMBER: _ClassVar[int]
    PROB_FIELD_NUMBER: _ClassVar[int]
    label: str
    prob: float
    def __init__(self, label: _Optional[str] = ..., prob: _Optional[float] = ...) -> None: ...

class FileHeader(_message.Message):
    __slots__ = ("kind", "filename", "size_bytes")
    KIND_FIELD_NUMBER: _ClassVar[int]
    FILENAME_FIELD_NUMBER: _ClassVar[int]
    SIZE_BYTES_FIELD_NUMBER: _ClassVar[int]
    kind: FileKind
    filename: str
    size_bytes: int
    def __init__(self, kind: _Optional[_Union[FileKind, str]] = ..., filename: _Optional[str] = ..., size_bytes: _Optional[int] = ...) -> None: ...

class UploadModelRequest(_message.Message):
    __slots__ = ("header", "chunk")
    HEADER_FIELD_NUMBER: _ClassVar[int]
    CHUNK_FIELD_NUMBER: _ClassVar[int]
    header: FileHeader
    chunk: bytes
    def __init__(self, header: _Optional[_Union[FileHeader, _Mapping]] = ..., chunk: _Optional[bytes] = ...) -> None: ...

class UploadModelResponse(_message.Message):
    __slots__ = ("reloaded", "num_classes", "sequence_len", "feature_dim")
    RELOADED_FIELD_NUMBER: _ClassVar[int]
    NUM_CLASSES_FIELD_NUMBER: _ClassVar[int]
    SEQUENCE_LEN_FIELD_NUMBER: _ClassVar[int]
    FEATURE_DIM_FIELD_NUMBER: _ClassVar[int]
    reloaded: bool
    num_classes: int
    sequence_len: int
    feature_dim: int
    def __init__(self, reloaded: _Optional[bool] = ..., num_classes: _Optional[int] = ..., sequence_len: _Optional[int] = ..., feature_dim: _Optional[int] = ...) -> None: ...

class StreamLogsRequest(_message.Message):
    __slots__ = ("min_level", "history_lines")
    MIN_LEVEL_FIELD_NUMBER: _ClassVar[int]
    HISTORY_LINES_FIELD_NUMBER: _ClassVar[int]
    min_level: LogLevel
    history_lines: int
    def __init__(self, min_level: _Optional[_Union[LogLevel, str]] = ..., history_lines: _Optional[int] = ...) -> None: ...

class LogEntry(_message.Message):
    __slots__ = ("timestamp_ms", "level", "logger", "message")
    TIMESTAMP_MS_FIELD_NUMBER: _ClassVar[int]
    LEVEL_FIELD_NUMBER: _ClassVar[int]
    LOGGER_FIELD_NUMBER: _ClassVar[int]
    MESSAGE_FIELD_NUMBER: _ClassVar[int]
    timestamp_ms: int
    level: LogLevel
    logger: str
    message: str
    def __init__(self, timestamp_ms: _Optional[int] = ..., level: _Optional[_Union[LogLevel, str]] = ..., logger: _Optional[str] = ..., message: _Optional[str] = ...) -> None: ...

class GetTuningRequest(_message.Message):
    __slots__ = ()
    def __init__(self) -> None: ...

class SetTuningRequest(_message.Message):
    __slots__ = ("confidence_threshold", "idle_min_frames_with_hands", "idle_motion_std_threshold")
    CONFIDENCE_THRESHOLD_FIELD_NUMBER: _ClassVar[int]
    IDLE_MIN_FRAMES_WITH_HANDS_FIELD_NUMBER: _ClassVar[int]
    IDLE_MOTION_STD_THRESHOLD_FIELD_NUMBER: _ClassVar[int]
    confidence_threshold: float
    idle_min_frames_with_hands: int
    idle_motion_std_threshold: float
    def __init__(self, confidence_threshold: _Optional[float] = ..., idle_min_frames_with_hands: _Optional[int] = ..., idle_motion_std_threshold: _Optional[float] = ...) -> None: ...

class TuningState(_message.Message):
    __slots__ = ("confidence_threshold", "idle_min_frames_with_hands", "idle_motion_std_threshold", "model_loaded", "num_classes", "sequence_len", "feature_dim")
    CONFIDENCE_THRESHOLD_FIELD_NUMBER: _ClassVar[int]
    IDLE_MIN_FRAMES_WITH_HANDS_FIELD_NUMBER: _ClassVar[int]
    IDLE_MOTION_STD_THRESHOLD_FIELD_NUMBER: _ClassVar[int]
    MODEL_LOADED_FIELD_NUMBER: _ClassVar[int]
    NUM_CLASSES_FIELD_NUMBER: _ClassVar[int]
    SEQUENCE_LEN_FIELD_NUMBER: _ClassVar[int]
    FEATURE_DIM_FIELD_NUMBER: _ClassVar[int]
    confidence_threshold: float
    idle_min_frames_with_hands: int
    idle_motion_std_threshold: float
    model_loaded: bool
    num_classes: int
    sequence_len: int
    feature_dim: int
    def __init__(self, confidence_threshold: _Optional[float] = ..., idle_min_frames_with_hands: _Optional[int] = ..., idle_motion_std_threshold: _Optional[float] = ..., model_loaded: _Optional[bool] = ..., num_classes: _Optional[int] = ..., sequence_len: _Optional[int] = ..., feature_dim: _Optional[int] = ...) -> None: ...
