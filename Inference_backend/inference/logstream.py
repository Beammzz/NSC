"""Logging handler feeding the StreamLogs RPC.

A single ``LogBroadcaster`` is attached to the root logger. It keeps a ring
buffer of recent records (history replay) and fans live records out to
per-subscriber queues. ``emit`` never blocks: a subscriber that stops
draining its queue loses records rather than stalling the process's logging.
"""

import logging
import queue
import threading
import time
from collections import deque
from dataclasses import dataclass

RING_BUFFER_SIZE = 500
SUBSCRIBER_QUEUE_SIZE = 1000

# python logging levelno -> proto LogLevel value (LOG_LEVEL_DEBUG=1 .. ERROR=4;
# CRITICAL folds into ERROR).
_LEVEL_TO_PB = {
    logging.DEBUG: 1,
    logging.INFO: 2,
    logging.WARNING: 3,
    logging.ERROR: 4,
    logging.CRITICAL: 4,
}


def pb_level(levelno: int) -> int:
    """Nearest proto LogLevel for an arbitrary levelno (customs round down)."""
    for threshold in (logging.CRITICAL, logging.ERROR, logging.WARNING, logging.INFO):
        if levelno >= threshold:
            return _LEVEL_TO_PB[threshold]
    return _LEVEL_TO_PB[logging.DEBUG]


@dataclass
class LogEvent:
    timestamp_ms: int  # Unix epoch milliseconds
    level: int  # proto LogLevel value
    logger: str
    message: str


class LogBroadcaster(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self._ring: deque[LogEvent] = deque(maxlen=RING_BUFFER_SIZE)
        self._subscribers: list[queue.Queue] = []
        self._state_lock = threading.Lock()

    def emit(self, record: logging.LogRecord) -> None:
        try:
            event = LogEvent(
                timestamp_ms=int(record.created * 1000),  # seconds -> ms
                level=pb_level(record.levelno),
                logger=record.name,
                message=self.format(record),
            )
        except Exception:
            self.handleError(record)
            return
        with self._state_lock:
            self._ring.append(event)
            subscribers = list(self._subscribers)
        for q in subscribers:
            try:
                q.put_nowait(event)
            except queue.Full:
                pass  # slow subscriber drops records; logging must not block

    def subscribe(self, history_lines: int) -> tuple[list[LogEvent], queue.Queue]:
        """Register a subscriber; returns (history to replay, live queue).

        History and registration happen under one lock so no record between
        them is lost or duplicated.
        """
        q: queue.Queue = queue.Queue(maxsize=SUBSCRIBER_QUEUE_SIZE)
        with self._state_lock:
            history = list(self._ring)[-history_lines:] if history_lines > 0 else []
            self._subscribers.append(q)
        return history, q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._state_lock:
            if q in self._subscribers:
                self._subscribers.remove(q)


def wall_now_ms() -> int:
    """Current Unix epoch milliseconds."""
    return int(time.time() * 1000)
