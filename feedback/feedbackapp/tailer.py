"""Tailer - poll a held fd, emit new complete lines as ORDERED BATCHES.

Design decisions baked in (from the build brief, superseding architecture-v0):
- Poll `os.fstat` on a HELD fd every ~100ms. NOT kqueue/watchdog: the latency
  win is nothing against the ~3s speech-to-disk floor and it costs CI
  portability.
- Read appends into a bytearray, split on b"\\n", KEEP THE LAST ELEMENT
  UNPARSED (torn-line handling): the producer flushes per line but a poll can
  still land mid-write.
- An unparseable COMPLETE line is logged and skipped, never crashes the tailer.
- Real loss is detected via `seq` gaps (seq is gapless by contract).
- Truncation/rotation (size < offset, or inode change) -> reopen and dedupe on
  seq so already-seen turns are not re-emitted.
- Persist (path, inode, offset, last_seq) to a sidecar for restart/resume.

CRITICAL: `poll()` returns ALL new turns from this tick as one ordered batch.
The orchestrator applies the whole batch to the window and evaluates the gate
ONCE per tick - never once per line - because TurnMerger flushes a whole
watermark-eligible prefix at once, so lines arrive in BURSTS.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional

from pydantic import ValidationError

from .models import Turn

log = logging.getLogger("feedback.tailer")


@dataclass
class TailerState:
    """Persisted to a sidecar so a restart resumes instead of re-emitting."""

    path: str
    inode: int
    offset: int
    last_seq: int  # highest seq emitted so far; -1 = nothing yet


class TailEvent:
    """Reasons the tailer noticed something beyond a plain append (for logging/warnings)."""

    SEQ_GAP = "seq_gap"
    ROTATED = "rotated"
    BAD_LINE = "bad_line"


@dataclass
class TickResult:
    turns: list[Turn]
    events: list[tuple[str, str]]  # (TailEvent, detail)


class Tailer:
    """Stateful poller. Call `poll()` on a timer; it returns a TickResult."""

    def __init__(self, path: Path, sidecar: Optional[Path] = None):
        self.path = Path(path)
        self.sidecar = sidecar
        self._fh = None
        self._inode: Optional[int] = None
        self._offset = 0
        self._buf = bytearray()
        self._last_seq = -1
        self._resume_from_sidecar()

    # --- lifecycle ----------------------------------------------------------

    def _resume_from_sidecar(self) -> None:
        if not self.sidecar or not self.sidecar.exists():
            return
        try:
            data = json.loads(self.sidecar.read_text())
            st = TailerState(**data)
        except (json.JSONDecodeError, TypeError, ValueError) as e:
            log.warning("ignoring unreadable sidecar %s: %s", self.sidecar, e)
            return
        if st.path != str(self.path):
            return  # sidecar is for a different file
        self._offset = st.offset
        self._last_seq = st.last_seq
        self._inode = st.inode

    def _persist(self) -> None:
        if not self.sidecar or self._inode is None:
            return
        st = TailerState(str(self.path), self._inode, self._offset, self._last_seq)
        tmp = self.sidecar.with_suffix(self.sidecar.suffix + ".tmp")
        tmp.write_text(json.dumps(asdict(st)))
        os.replace(tmp, self.sidecar)  # atomic

    def _open(self, events: list[tuple[str, str]]) -> bool:
        """(Re)open the file and reconcile our position with what's on disk.
        Sole owner of inode logic (so no code path double-emits ROTATED).
        Returns True if a fd is held.

        Rotation policy (review items 2+4, deliberately merged - they conflict on
        last_seq and an inode-change reset satisfies BOTH verified failures):
          - INODE CHANGED (file replaced live, or during downtime before this
            resume): a NEW stream. Discard the stale offset AND reset last_seq -
            the new file's seq counter is independent, so keeping the old
            threshold would silently drop a new meeting that restarts seq low.
          - TRUNCATE IN PLACE (same inode, offset past EOF): an in-place rewrite
            of the SAME stream. Re-read from the top but KEEP last_seq, so
            already-emitted seqs are deduped rather than replayed.
        """
        if not self.path.exists():
            return False
        fh = open(self.path, "rb")
        st = os.fstat(fh.fileno())  # one fstat; both inode and size come from it
        current = st.st_ino
        if self._inode is not None and current != self._inode:
            events.append((TailEvent.ROTATED, f"inode {self._inode} -> {current}"))
            self._offset = 0
            self._buf.clear()
            self._last_seq = -1  # new stream: seq dedupe must not span files
        self._fh = fh
        self._inode = current
        if self._offset > st.st_size:
            # Truncate in place (same inode): re-read from top, KEEP last_seq.
            self._offset = 0
            self._buf.clear()
        fh.seek(self._offset)
        return True

    def close(self) -> None:
        if self._fh:
            self._fh.close()
            self._fh = None

    # --- the poll -----------------------------------------------------------

    def poll(self) -> TickResult:
        events: list[tuple[str, str]] = []

        if self._fh is None:
            if not self._open(events):
                return TickResult([], events)

        try:
            stat = os.fstat(self._fh.fileno())
        except OSError:
            self.close()
            return TickResult([], events)

        # Rotation / truncation: inode changed on disk, or file shrank below our
        # offset. One stat, not exists()+stat() - this runs 10x/second, and the
        # exists() check was itself a syscall that the stat already answers.
        try:
            on_disk_inode = self.path.stat().st_ino
        except OSError:
            on_disk_inode = None
        if on_disk_inode is not None and on_disk_inode != self._inode:
            # Delegate ALL inode handling (event + resets) to _open so exactly one
            # ROTATED fires per rotation.
            self.close()
            if not self._open(events):
                return TickResult([], events)
            stat = os.fstat(self._fh.fileno())
        elif stat.st_size < self._offset:
            events.append((TailEvent.ROTATED, f"truncated: size {stat.st_size} < offset {self._offset}"))
            self._offset = 0
            self._buf.clear()
            self._fh.seek(0)

        # Read everything appended since last offset.
        chunk = self._fh.read()
        if chunk:
            self._offset += len(chunk)
            self._buf.extend(chunk)

        turns = self._drain_buffer(events)
        # Only when something actually moved. Unconditional persistence meant a
        # temp-file write + rename 10x/second - ~36k of them over an hour-long
        # meeting - for state that changes only when a turn arrives.
        if turns or events or chunk:
            self._persist()
        return TickResult(turns, events)

    def _drain_buffer(self, events: list[tuple[str, str]]) -> list[Turn]:
        """Split buffer on newlines; KEEP the last (possibly torn) element unparsed."""
        if b"\n" not in self._buf:
            return []  # nothing complete yet - the whole buffer is a torn line
        *complete, tail = self._buf.split(b"\n")
        self._buf = bytearray(tail)  # last element stays buffered (torn-line handling)

        turns: list[Turn] = []
        for raw in complete:
            raw = raw.strip()
            if not raw:
                continue
            turn = self._parse(raw, events)
            if turn is None:
                continue
            # Dedupe on seq (covers rotation/resume replays) and detect gaps.
            if turn.seq <= self._last_seq:
                continue  # already emitted
            if self._last_seq >= 0 and turn.seq != self._last_seq + 1:
                events.append((TailEvent.SEQ_GAP, f"expected {self._last_seq + 1}, got {turn.seq}"))
            self._last_seq = turn.seq
            turns.append(turn)
        return turns

    def _parse(self, raw: bytes, events: list[tuple[str, str]]) -> Optional[Turn]:
        try:
            obj = json.loads(raw)
            return Turn.model_validate(obj)
        except (json.JSONDecodeError, ValidationError, UnicodeDecodeError) as e:
            detail = f"{raw[:80]!r}: {e.__class__.__name__}"
            events.append((TailEvent.BAD_LINE, detail))
            log.warning("skipping unparseable line %s", detail)
            return None
