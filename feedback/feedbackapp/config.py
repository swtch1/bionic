"""Config loading: app config (yaml), resources registry (yaml), instructions (md).

instructions.md is plain markdown (Decision 9) - global + optional per-meeting
overlay, concatenated. resources.yaml + config.yaml are yaml. Four deps total
(anthropic, claude-agent-sdk, pydantic, pyyaml); this module uses pyyaml +
pydantic only.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path

import yaml
from pydantic import BaseModel, ValidationError

from .glanceability import Ceiling
from .hygiene import HygieneConfig
from .window import AntiSpamConfig


class Resource(BaseModel):
    name: str
    kind: str
    path: str
    desc: str


@dataclass
class AppConfig:
    gate_model: str
    responder_model: str
    poll_interval_seconds: float
    window: AntiSpamConfig
    hygiene: HygieneConfig
    resources: list[Resource]
    instructions: str
    # The glanceability ceilings the responder enforces (Decision 18). Loaded
    # straight into glanceability.Ceiling - no separate config type.
    glanceability: dict[str, Ceiling] = field(default_factory=dict)

    @cached_property
    def resource_registry_text(self) -> str:
        """Names + descriptions only - what the gate sees (no paths, no tools).

        Cached: the registry is immutable for the process lifetime, but this is
        called on every gate evaluation and re-tokenizes every description.
        """
        return "\n".join(
            f"- {r.name} ({r.kind}): {' '.join(r.desc.split())}" for r in self.resources
        )


# The user's live config - what load_config() reads by default. Lives outside
# the repo (Decision: 2026-07-29) so a `git pull` never clobbers a user's
# edited resources.yaml, and so the same config is shared by every checkout.
CONFIG_DIR = Path.home() / ".config" / "bionic"

# The bundled starter templates `init_config()` copies from. Distinct from
# CONFIG_DIR: this one ships in the repo and must never be treated as the
# live config (see the resources.yaml PLACEHOLDER comment in this directory).
DEFAULTS_DIR = Path(__file__).resolve().parent.parent / "config"


class ConfigError(Exception):
    """Config is missing, malformed, or missing a key.

    Exists so the CLI can print which file is at fault. Editing resources.yaml
    to point at your own repos is the FIRST thing a new user does, and a stray
    key used to surface as a bare pydantic traceback naming neither the file nor
    the field.
    """


def init_config(target_dir: Path | None = None, defaults_dir: Path | None = None) -> list[Path]:
    """Create target_dir with starter config files, if they don't already exist.

    Never overwrites a file that's already there - re-running `init` after
    editing resources.yaml must not clobber those edits. Returns the paths it
    actually created (empty list if everything already existed).
    """
    d = target_dir or CONFIG_DIR
    defaults = defaults_dir or DEFAULTS_DIR
    d.mkdir(parents=True, exist_ok=True)
    transcripts_dir = d / "transcripts"
    transcripts_dir.mkdir(exist_ok=True)

    created: list[Path] = []
    for name in ("config.yaml", "instructions.md"):
        dest = d / name
        if not dest.exists():
            dest.write_text((defaults / name).read_text())
            created.append(dest)

    resources_dest = d / "resources.yaml"
    if not resources_dest.exists():
        resources_dest.write_text(_starter_resources_yaml(transcripts_dir))
        created.append(resources_dest)

    return created


def _starter_resources_yaml(transcripts_dir: Path) -> str:
    return f"""\
# Resource registry (Decision 10). Point these at your own repos and docs -
# uncomment and edit the examples below, or add your own in the same shape.
#
# Gate sees only {{name, desc}} (cheap, no tools) to judge in-scope-ness.
# Responder gets {{path}} to actually read/grep. NO vector DB in v0.

resources:
  # - name: auth-service
  #   kind: repo
  #   path: ~/code/auth-service
  #   desc: >
  #     Authentication service. Owns login, session issuance, and token
  #     refresh.

  # - name: platform-docs
  #   kind: docs
  #   path: ~/docs/platform
  #   desc: >
  #     Architecture decision records and runbooks - service ownership,
  #     the cutover/rollback playbook, on-call.

  # - name: gateway
  #   kind: repo
  #   path: ~/code/gateway
  #   desc: >
  #     Edge API gateway. Routing, rate limiting, request auth verification.

  - name: past-meetings
    kind: transcripts
    path: {transcripts_dir}
    desc: >
      Diarized transcripts of past meetings, one JSONL file per meeting,
      named YYYY-MM-DD-HH-MM-SS-<short-description>.jsonl. Read these to
      recall what was discussed or decided in an earlier conversation.
"""


def load_config(config_dir: Path | None = None) -> AppConfig:
    d = config_dir or CONFIG_DIR
    if not d.exists():
        raise ConfigError(
            f"config directory not found: {d}\n"
            "Run `make init` (or `python -m feedbackapp init`) to create it."
        )
    try:
        return _load(d)
    except ConfigError:
        raise
    except FileNotFoundError as e:
        raise ConfigError(
            f"config file not found: {e.filename} (expected {d} - run `make init` "
            "if this directory is missing files)"
        ) from e
    except yaml.YAMLError as e:
        raise ConfigError(f"invalid YAML under {d}: {e}") from e
    except KeyError as e:
        raise ConfigError(f"missing required key {e} in {d / 'config.yaml'}") from e
    except (TypeError, ValidationError) as e:
        raise ConfigError(f"invalid config under {d}: {e}") from e


def _load(d: Path) -> AppConfig:
    raw = yaml.safe_load((d / "config.yaml").read_text())
    if not isinstance(raw, dict):
        raise ConfigError(f"{d / 'config.yaml'} is empty or not a mapping")

    anti_spam = AntiSpamConfig(
        window_size=raw["window"]["window_size"],
        cooldown_seconds=raw["anti_spam"]["cooldown_seconds"],
        responses_per_min=raw["anti_spam"]["responses_per_min"],
        recently_addressed_size=raw["anti_spam"]["recently_addressed_size"],
    )
    hyg = HygieneConfig(**raw["hygiene"])

    resources_raw = (yaml.safe_load((d / "resources.yaml").read_text()) or {}).get("resources") or []
    try:
        resources = [Resource(**r) for r in resources_raw]
    except (TypeError, ValidationError) as e:
        raise ConfigError(f"invalid entry in {d / 'resources.yaml'}: {e}") from e

    instructions = (d / "instructions.md").read_text()
    overlay = d / "instructions.local.md"
    if overlay.exists():
        instructions = instructions + "\n\n" + overlay.read_text()

    glance = {
        k: Ceiling(**v) for k, v in (raw.get("glanceability") or {}).items()
    }

    return AppConfig(
        gate_model=raw["models"]["gate"],
        responder_model=raw["models"]["responder"],
        poll_interval_seconds=raw["tailer"]["poll_interval_seconds"],
        window=anti_spam,
        hygiene=hyg,
        resources=resources,
        instructions=instructions,
        glanceability=glance,
    )
