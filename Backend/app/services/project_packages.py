"""Versioned, self-contained ICTW project package import and export.

The package deliberately carries author-visible book data only.  Runtime jobs,
LLM credentials, hidden Writer candidates and rejected-candidate evidence are
not serialised, so a backup never broadens the public data surface.
"""

from __future__ import annotations

import hashlib
import io
import json
import zipfile
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    Book,
    BookAgentModelBinding,
    BookAgentPersona,
    Chapter,
    ChapterArchiveFact,
    ChapterArchiveFactParticipant,
    ChapterArchiveRevision,
    ChapterArchiveStateDelta,
    ChapterCharacter,
    Character,
    LLMProfile,
)
from app.services.archive_v2 import archive_health_summaries, archive_input_fingerprint
from app.services.character_state_projection import rebuild_book_projection
from app.services.personas import AGENT_ROLES
from app.services.search_index import rebuild_book_search_index


PROJECT_MEDIA_TYPE = "application/vnd.ictw.project+zip"
PROJECT_FORMAT_VERSION = 1
PROJECT_ENTRY_NAMES = (
    "book.json",
    "characters.json",
    "chapters.json",
    "archives.json",
    "personas.json",
    "model-bindings.json",
)
_MANIFEST_NAME = "manifest.json"
_ALLOWED_NAMES = frozenset({_MANIFEST_NAME, *PROJECT_ENTRY_NAMES})
_MAX_PACKAGE_BYTES = 50 * 1024 * 1024
_MAX_ENTRY_BYTES = 20 * 1024 * 1024
_MAX_TOTAL_UNCOMPRESSED_BYTES = 45 * 1024 * 1024


class ProjectPackageError(ValueError):
    """Safe, client-displayable package validation failure."""


def _json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _json_load(raw: bytes, *, entry_name: str) -> Any:
    def reject_duplicates(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise ProjectPackageError(f"{entry_name} contains duplicate key")
            result[key] = value
        return result

    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProjectPackageError(f"{entry_name} is not valid UTF-8 JSON") from exc


def _string(value: object, *, field: str, maximum: int = 200_000, allow_empty: bool = True) -> str:
    if not isinstance(value, str) or len(value) > maximum or (not allow_empty and not value.strip()):
        raise ProjectPackageError(f"invalid {field}")
    return value


def _int(value: object, *, field: str, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise ProjectPackageError(f"invalid {field}")
    return value


def _list(value: object, *, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise ProjectPackageError(f"invalid {field}")
    return value


def _mapping(value: object, *, field: str, exact_keys: set[str] | None = None) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProjectPackageError(f"invalid {field}")
    if exact_keys is not None and set(value) != exact_keys:
        raise ProjectPackageError(f"invalid {field} fields")
    return value


def _safe_json(value: object, *, field: str) -> object:
    """Round-trip JSON to reject non-JSON SQLAlchemy values before packaging."""
    try:
        return json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False))
    except (TypeError, ValueError) as exc:
        raise ProjectPackageError(f"invalid {field}") from exc


def _package_entries(db: Session, book: Book) -> dict[str, bytes]:
    chapters = db.scalars(
        select(Chapter).where(Chapter.book_id == book.id).order_by(Chapter.index, Chapter.id)
    ).all()
    characters = db.scalars(
        select(Character).where(Character.book_id == book.id).order_by(Character.created_at, Character.id)
    ).all()
    links_by_chapter: dict[str, list[str]] = {}
    chapter_ids = [chapter.id for chapter in chapters]
    if chapter_ids:
        for link in db.scalars(
            select(ChapterCharacter)
            .where(ChapterCharacter.chapter_id.in_(chapter_ids))
            .order_by(ChapterCharacter.chapter_id, ChapterCharacter.character_id)
        ).all():
            links_by_chapter.setdefault(link.chapter_id, []).append(link.character_id)

    # Only an archive that is valid *now* is a portable memory source.  This
    # avoids reviving stale/partial attempts in a recovered book.
    health = archive_health_summaries(db, chapters)
    active_ids = [
        chapter.active_archive_revision_id
        for chapter in chapters
        if health.get(chapter.id, {}).get("archive_schema") == "v2" and chapter.active_archive_revision_id
    ]
    revisions_by_id: dict[str, ChapterArchiveRevision] = {}
    facts_by_revision: dict[str, list[ChapterArchiveFact]] = {}
    participants_by_fact: dict[str, list[str]] = {}
    deltas_by_revision: dict[str, list[ChapterArchiveStateDelta]] = {}
    if active_ids:
        revisions_by_id = {
            row.id: row
            for row in db.scalars(
                select(ChapterArchiveRevision).where(ChapterArchiveRevision.id.in_(active_ids))
            ).all()
        }
        facts = db.scalars(
            select(ChapterArchiveFact)
            .where(ChapterArchiveFact.revision_id.in_(active_ids))
            .order_by(ChapterArchiveFact.revision_id, ChapterArchiveFact.position, ChapterArchiveFact.id)
        ).all()
        for fact in facts:
            facts_by_revision.setdefault(fact.revision_id, []).append(fact)
        fact_ids = [fact.id for fact in facts]
        if fact_ids:
            for participant in db.scalars(
                select(ChapterArchiveFactParticipant)
                .where(ChapterArchiveFactParticipant.fact_id.in_(fact_ids))
                .order_by(ChapterArchiveFactParticipant.fact_id, ChapterArchiveFactParticipant.position)
            ).all():
                participants_by_fact.setdefault(participant.fact_id, []).append(participant.character_id)
        for delta in db.scalars(
            select(ChapterArchiveStateDelta)
            .where(ChapterArchiveStateDelta.revision_id.in_(active_ids))
            .order_by(
                ChapterArchiveStateDelta.revision_id,
                ChapterArchiveStateDelta.position,
                ChapterArchiveStateDelta.id,
            )
        ).all():
            deltas_by_revision.setdefault(delta.revision_id, []).append(delta)

    archives: list[dict[str, object]] = []
    for chapter in chapters:
        revision = revisions_by_id.get(chapter.active_archive_revision_id or "")
        if revision is None:
            continue
        facts = [
            {
                "fact_ref": fact.fact_ref,
                "type": fact.fact_type,
                "importance": fact.importance,
                "text": fact.fact_text,
                "start_id": fact.start_id,
                "end_id": fact.end_id,
                "participant_ids": participants_by_fact.get(fact.id, []),
            }
            for fact in facts_by_revision.get(revision.id, [])
        ]
        fact_positions = {fact.id: position for position, fact in enumerate(facts_by_revision.get(revision.id, []), start=1)}
        archives.append(
            {
                "chapter_id": chapter.id,
                "summary": revision.summary,
                "facts": facts,
                "deltas": [
                    {
                        "fact_position": fact_positions[delta.fact_id],
                        "position": delta.position,
                        "character_id": delta.character_id,
                        "other_character_id": delta.other_character_id,
                        "scope": delta.scope,
                        "slot": delta.slot,
                        "operation": delta.operation,
                        "value": delta.value,
                        "batch_id": delta.batch_id,
                    }
                    for delta in deltas_by_revision.get(revision.id, [])
                ],
            }
        )

    personas = db.scalars(
        select(BookAgentPersona)
        .where(BookAgentPersona.book_id == book.id)
        .order_by(BookAgentPersona.agent_role)
    ).all()
    bindings = db.scalars(
        select(BookAgentModelBinding)
        .where(BookAgentModelBinding.book_id == book.id)
        .order_by(BookAgentModelBinding.agent_role)
    ).all()
    return {
        "book.json": _json_bytes({"title": book.title, "world_setting": book.world_setting}),
        "characters.json": _json_bytes(
            [
                {
                    "id": character.id,
                    "name": character.name,
                    "role": character.role,
                    "fixed_profile": character.fixed_profile,
                }
                for character in characters
            ]
        ),
        "chapters.json": _json_bytes(
            [
                {
                    "id": chapter.id,
                    "index": chapter.index,
                    "title": chapter.title,
                    "user_prompt": chapter.user_prompt,
                    "target_word_count": chapter.target_word_count,
                    "author_note": chapter.author_note,
                    "draft_text": chapter.draft_text,
                    "headline": chapter.headline,
                    "long_summary": chapter.long_summary,
                    "state_changes": _safe_json(chapter.state_changes, field="chapter state_changes"),
                    "unresolved_items": _safe_json(chapter.unresolved_items, field="chapter unresolved_items"),
                    "atomic_memories": _safe_json(chapter.atomic_memories, field="chapter atomic_memories"),
                    "exempted_character_names": _safe_json(chapter.exempted_character_names, field="chapter exempted names"),
                    "status": chapter.status,
                    "source": chapter.source,
                    "character_ids": links_by_chapter.get(chapter.id, []),
                }
                for chapter in chapters
            ]
        ),
        "archives.json": _json_bytes(archives),
        "personas.json": _json_bytes(
            [{"agent_role": item.agent_role, "editable_persona": item.editable_persona} for item in personas]
        ),
        "model-bindings.json": _json_bytes(
            [
                {
                    "agent_role": item.agent_role,
                    "llm_profile_id": item.llm_profile_id,
                    "thinking_enabled": item.thinking_enabled,
                    "reasoning_effort": item.reasoning_effort,
                    "temperature": item.temperature,
                }
                for item in bindings
            ]
        ),
    }


def export_project_package(db: Session, book: Book) -> bytes:
    entries = _package_entries(db, book)
    manifest = {
        "format": "ictwbook",
        "format_version": PROJECT_FORMAT_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "entries": {
            name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
            for name, data in sorted(entries.items())
        },
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr(_MANIFEST_NAME, _json_bytes(manifest))
        for name, data in sorted(entries.items()):
            archive.writestr(name, data)
    package = buffer.getvalue()
    if len(package) > _MAX_PACKAGE_BYTES:
        raise ProjectPackageError("project package exceeds size limit")
    return package


def _read_project_package(payload: bytes) -> dict[str, Any]:
    if not payload or len(payload) > _MAX_PACKAGE_BYTES:
        raise ProjectPackageError("project package exceeds size limit")
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            infos = archive.infolist()
            names = [item.filename for item in infos]
            if len(infos) != len(set(names)) or set(names) != _ALLOWED_NAMES:
                raise ProjectPackageError("project package contains unsupported entries")
            if any(
                item.is_dir()
                or item.filename.startswith("/")
                or "\\" in item.filename
                or ".." in item.filename.split("/")
                or item.file_size > _MAX_ENTRY_BYTES
                for item in infos
            ):
                raise ProjectPackageError("project package contains unsafe paths or oversized entries")
            if sum(item.file_size for item in infos) > _MAX_TOTAL_UNCOMPRESSED_BYTES:
                raise ProjectPackageError("project package exceeds uncompressed size limit")
            raw_entries = {item.filename: archive.read(item) for item in infos}
    except (zipfile.BadZipFile, OSError) as exc:
        raise ProjectPackageError("project package is not a valid ZIP") from exc

    manifest = _mapping(
        _json_load(raw_entries[_MANIFEST_NAME], entry_name=_MANIFEST_NAME),
        field="manifest",
        exact_keys={"format", "format_version", "created_at", "entries"},
    )
    if manifest["format"] != "ictwbook" or manifest["format_version"] != PROJECT_FORMAT_VERSION:
        raise ProjectPackageError("unsupported project package format")
    _string(manifest["created_at"], field="manifest creation time", maximum=100, allow_empty=False)
    entries = _mapping(manifest["entries"], field="manifest entries")
    if set(entries) != set(PROJECT_ENTRY_NAMES):
        raise ProjectPackageError("manifest entry list does not match package")
    decoded: dict[str, Any] = {}
    for name in PROJECT_ENTRY_NAMES:
        metadata = _mapping(entries[name], field=f"manifest entry {name}", exact_keys={"sha256", "size"})
        raw = raw_entries[name]
        if metadata["sha256"] != hashlib.sha256(raw).hexdigest() or metadata["size"] != len(raw):
            raise ProjectPackageError(f"project package integrity check failed for {name}")
        decoded[name] = _json_load(raw, entry_name=name)
    return decoded


def _validated_records(decoded: dict[str, Any]) -> dict[str, Any]:
    book = _mapping(decoded["book.json"], field="book", exact_keys={"title", "world_setting"})
    _string(book["title"], field="book title", maximum=10_000, allow_empty=False)
    _string(book["world_setting"], field="world setting", maximum=200_000)
    characters = _list(decoded["characters.json"], field="characters")
    chapters = _list(decoded["chapters.json"], field="chapters")
    archives = _list(decoded["archives.json"], field="archives")
    personas = _list(decoded["personas.json"], field="personas")
    bindings = _list(decoded["model-bindings.json"], field="model bindings")
    if any(len(rows) > 20_000 for rows in (characters, chapters, archives)):
        raise ProjectPackageError("project package has too many records")
    character_ids: set[str] = set()
    for item in characters:
        row = _mapping(item, field="character", exact_keys={"id", "name", "role", "fixed_profile"})
        source_id = _string(row["id"], field="character id", maximum=200, allow_empty=False)
        if source_id in character_ids:
            raise ProjectPackageError("duplicate character id")
        character_ids.add(source_id)
        _string(row["name"], field="character name", maximum=10_000, allow_empty=False)
        _string(row["role"], field="character role", maximum=10_000)
        _string(row["fixed_profile"], field="character fixed profile", maximum=200_000)
    chapter_ids: set[str] = set()
    chapter_indexes: set[int] = set()
    for item in chapters:
        row = _mapping(
            item,
            field="chapter",
            exact_keys={
                "id", "index", "title", "user_prompt", "target_word_count", "author_note", "draft_text",
                "headline", "long_summary", "state_changes", "unresolved_items", "atomic_memories",
                "exempted_character_names", "status", "source", "character_ids",
            },
        )
        source_id = _string(row["id"], field="chapter id", maximum=200, allow_empty=False)
        index = _int(row["index"], field="chapter index", minimum=1)
        if source_id in chapter_ids or index in chapter_indexes:
            raise ProjectPackageError("duplicate chapter id or index")
        chapter_ids.add(source_id)
        chapter_indexes.add(index)
        for name in ("title", "user_prompt", "author_note", "draft_text", "headline", "long_summary", "status", "source"):
            _string(row[name], field=f"chapter {name}")
        _int(row["target_word_count"], field="target word count", minimum=1)
        for name in ("state_changes", "unresolved_items", "atomic_memories", "exempted_character_names", "character_ids"):
            _list(row[name], field=f"chapter {name}")
        if any(not isinstance(character_id, str) or character_id not in character_ids for character_id in row["character_ids"]):
            raise ProjectPackageError("chapter references an unknown character")
        if len(set(row["character_ids"])) != len(row["character_ids"]):
            raise ProjectPackageError("chapter character links are duplicated")
        _safe_json(row["state_changes"], field="chapter state_changes")
        _safe_json(row["unresolved_items"], field="chapter unresolved_items")
        _safe_json(row["atomic_memories"], field="chapter atomic_memories")
        _safe_json(row["exempted_character_names"], field="chapter exempted names")
    persona_roles: set[str] = set()
    for item in personas:
        row = _mapping(item, field="persona", exact_keys={"agent_role", "editable_persona"})
        role = _string(row["agent_role"], field="persona role", maximum=64, allow_empty=False)
        if role not in AGENT_ROLES or role in persona_roles:
            raise ProjectPackageError("duplicate persona role")
        persona_roles.add(role)
        _string(row["editable_persona"], field="editable persona", maximum=8_000, allow_empty=False)
    binding_roles: set[str] = set()
    for item in bindings:
        row = _mapping(
            item,
            field="model binding",
            exact_keys={"agent_role", "llm_profile_id", "thinking_enabled", "reasoning_effort", "temperature"},
        )
        role = _string(row["agent_role"], field="model binding role", maximum=64, allow_empty=False)
        if role not in AGENT_ROLES or role in binding_roles:
            raise ProjectPackageError("duplicate model binding role")
        binding_roles.add(role)
        if row["llm_profile_id"] is not None:
            _string(row["llm_profile_id"], field="model binding profile", maximum=200, allow_empty=False)
        if row["thinking_enabled"] is not None and not isinstance(row["thinking_enabled"], bool):
            raise ProjectPackageError("invalid model binding thinking flag")
        if row["reasoning_effort"] is not None:
            _string(row["reasoning_effort"], field="model binding effort", maximum=64, allow_empty=False)
        if row["temperature"] is not None and (not isinstance(row["temperature"], (int, float)) or isinstance(row["temperature"], bool)):
            raise ProjectPackageError("invalid model binding temperature")
    archive_chapters: set[str] = set()
    for item in archives:
        row = _mapping(item, field="archive", exact_keys={"chapter_id", "summary", "facts", "deltas"})
        chapter_id = _string(row["chapter_id"], field="archive chapter", maximum=200, allow_empty=False)
        if chapter_id not in chapter_ids or chapter_id in archive_chapters:
            raise ProjectPackageError("duplicate or unknown archive chapter")
        archive_chapters.add(chapter_id)
        _string(row["summary"], field="archive summary", maximum=4_000, allow_empty=False)
        facts = _list(row["facts"], field="archive facts")
        if len(facts) > 8:
            raise ProjectPackageError("archive has too many facts")
        fact_refs: set[str] = set()
        fact_participants: list[set[str]] = []
        for fact in facts:
            fact_row = _mapping(
                fact,
                field="archive fact",
                exact_keys={"fact_ref", "type", "importance", "text", "start_id", "end_id", "participant_ids"},
            )
            fact_ref = _string(fact_row["fact_ref"], field="fact ref", maximum=16, allow_empty=False)
            if fact_ref in fact_refs:
                raise ProjectPackageError("duplicate archive fact ref")
            fact_refs.add(fact_ref)
            if fact_row["type"] not in {"剧情", "决定", "关系", "认知", "未决", "状态"}:
                raise ProjectPackageError("invalid archive fact type")
            _int(fact_row["importance"], field="fact importance", minimum=1)
            if fact_row["importance"] > 3:
                raise ProjectPackageError("invalid archive fact importance")
            for field_name in ("text", "start_id", "end_id"):
                _string(fact_row[field_name], field=f"fact {field_name}", maximum=500, allow_empty=False)
            participants = _list(fact_row["participant_ids"], field="fact participants")
            if len(participants) > 4 or len(set(participants)) != len(participants) or any(pid not in character_ids for pid in participants):
                raise ProjectPackageError("archive fact references unknown participants")
            fact_participants.append(set(participants))
        deltas = _list(row["deltas"], field="archive deltas")
        if len(deltas) > 18:
            raise ProjectPackageError("archive has too many state deltas")
        delta_positions: set[int] = set()
        for delta in deltas:
            delta_row = _mapping(
                delta,
                field="archive delta",
                exact_keys={"fact_position", "position", "character_id", "other_character_id", "scope", "slot", "operation", "value", "batch_id"},
            )
            _int(delta_row["fact_position"], field="delta fact position", minimum=1)
            if delta_row["fact_position"] > len(facts):
                raise ProjectPackageError("archive delta references unknown fact")
            position = _int(delta_row["position"], field="delta position", minimum=1)
            if position in delta_positions:
                raise ProjectPackageError("duplicate archive delta position")
            delta_positions.add(position)
            if delta_row["character_id"] not in character_ids:
                raise ProjectPackageError("archive delta references unknown character")
            if delta_row["other_character_id"] is not None and delta_row["other_character_id"] not in character_ids:
                raise ProjectPackageError("archive delta references unknown related character")
            if delta_row["scope"] not in {"snapshot", "persistent", "relationship"} or delta_row["operation"] not in {"set", "clear"}:
                raise ProjectPackageError("invalid archive delta")
            _string(delta_row["slot"], field="delta slot", maximum=64, allow_empty=False)
            _string(delta_row["batch_id"], field="delta batch id", maximum=64)
            if delta_row["operation"] == "set":
                _string(delta_row["value"], field="delta value", maximum=300, allow_empty=False)
            elif delta_row["value"] is not None:
                raise ProjectPackageError("clear delta must not have a value")
            participants = fact_participants[delta_row["fact_position"] - 1]
            if delta_row["character_id"] not in participants:
                raise ProjectPackageError("archive delta owner must participate in its fact")
            if delta_row["scope"] == "snapshot":
                if (
                    delta_row["other_character_id"] is not None
                    or delta_row["slot"] not in {"当前位置", "当前行动", "情绪状态"}
                    or not delta_row["batch_id"]
                ):
                    raise ProjectPackageError("invalid snapshot archive delta")
            elif delta_row["scope"] == "persistent":
                if (
                    delta_row["other_character_id"] is not None
                    or delta_row["slot"] not in {"身体状态", "当前目标", "秘密状态"}
                    or delta_row["batch_id"]
                ):
                    raise ProjectPackageError("invalid persistent archive delta")
            else:
                if (
                    delta_row["other_character_id"] is None
                    or delta_row["other_character_id"] == delta_row["character_id"]
                    or delta_row["other_character_id"] not in participants
                    or len(participants) != 2
                    or delta_row["slot"] != "relationship"
                    or delta_row["batch_id"]
                ):
                    raise ProjectPackageError("invalid relationship archive delta")
    return {
        "book": book,
        "characters": characters,
        "chapters": chapters,
        "archives": archives,
        "personas": personas,
        "bindings": bindings,
    }


def import_project_package(db: Session, payload: bytes) -> tuple[Book, list[dict[str, str]]]:
    """Validate everything before writing, then restore a new independent book."""
    records = _validated_records(_read_project_package(payload))
    warnings: list[dict[str, str]] = []
    binding_profile_ids = {
        item["llm_profile_id"] for item in records["bindings"] if item["llm_profile_id"] is not None
    }
    known_profile_ids = set()
    if binding_profile_ids:
        known_profile_ids = set(
            db.scalars(select(LLMProfile.id).where(LLMProfile.id.in_(binding_profile_ids))).all()
        )
    try:
        book = Book(title=records["book"]["title"], world_setting=records["book"]["world_setting"])
        db.add(book)
        db.flush()
        character_ids: dict[str, str] = {}
        for item in records["characters"]:
            character = Character(
                book_id=book.id,
                name=item["name"],
                role=item["role"],
                fixed_profile=item["fixed_profile"],
            )
            db.add(character)
            db.flush()
            character_ids[item["id"]] = character.id
        chapters_by_source: dict[str, Chapter] = {}
        for item in sorted(records["chapters"], key=lambda row: row["index"]):
            status = "finalized" if item["status"] == "finalized" else "draft_ready"
            chapter = Chapter(
                book_id=book.id,
                index=item["index"],
                title=item["title"],
                user_prompt=item["user_prompt"],
                target_word_count=item["target_word_count"],
                author_note=item["author_note"],
                draft_text=item["draft_text"],
                headline=item["headline"],
                long_summary=item["long_summary"],
                state_changes=item["state_changes"],
                unresolved_items=item["unresolved_items"],
                atomic_memories=item["atomic_memories"],
                exempted_character_names=item["exempted_character_names"],
                status=status,
                archive_status="stale",
                legacy_archive_eligible=False,
                source=item["source"],
            )
            db.add(chapter)
            db.flush()
            chapters_by_source[item["id"]] = chapter
            for character_id in item["character_ids"]:
                db.add(ChapterCharacter(chapter_id=chapter.id, character_id=character_ids[character_id]))
        db.flush()
        for item in records["personas"]:
            db.add(
                BookAgentPersona(
                    book_id=book.id,
                    agent_role=item["agent_role"],
                    editable_persona=item["editable_persona"],
                )
            )
        for item in records["bindings"]:
            profile_id = item["llm_profile_id"]
            if profile_id is not None and profile_id not in known_profile_ids:
                warnings.append(
                    {
                        "code": "model_binding_profile_missing",
                        "message": f"模型覆盖 {item['agent_role']} 引用的 Profile 不存在，已改为跟随全局",
                    }
                )
                continue
            db.add(
                BookAgentModelBinding(
                    book_id=book.id,
                    agent_role=item["agent_role"],
                    llm_profile_id=profile_id,
                    thinking_enabled=item["thinking_enabled"],
                    reasoning_effort=item["reasoning_effort"],
                    temperature=item["temperature"],
                )
            )
        db.flush()
        for item in records["archives"]:
            chapter = chapters_by_source[item["chapter_id"]]
            if chapter.status != "finalized":
                raise ProjectPackageError("only finalized chapters may carry an active archive")
            revision = ChapterArchiveRevision(
                chapter_id=chapter.id,
                revision=1,
                provenance="manual_retry",
                input_fingerprint="0" * 64,
                status="complete",
                is_active=True,
                summary=item["summary"],
                model_name=None,
            )
            db.add(revision)
            db.flush()
            facts: list[ChapterArchiveFact] = []
            for position, fact in enumerate(item["facts"], start=1):
                row = ChapterArchiveFact(
                    revision_id=revision.id,
                    position=position,
                    fact_ref=fact["fact_ref"],
                    fact_type=fact["type"],
                    importance=fact["importance"],
                    fact_text=fact["text"],
                    start_id=fact["start_id"],
                    end_id=fact["end_id"],
                )
                db.add(row)
                db.flush()
                facts.append(row)
                for participant_position, character_id in enumerate(fact["participant_ids"], start=1):
                    db.add(
                        ChapterArchiveFactParticipant(
                            fact_id=row.id,
                            character_id=character_ids[character_id],
                            position=participant_position,
                        )
                    )
            db.flush()
            for delta in item["deltas"]:
                db.add(
                    ChapterArchiveStateDelta(
                        revision_id=revision.id,
                        fact_id=facts[delta["fact_position"] - 1].id,
                        position=delta["position"],
                        character_id=character_ids[delta["character_id"]],
                        other_character_id=(
                            character_ids[delta["other_character_id"]]
                            if delta["other_character_id"] is not None
                            else None
                        ),
                        scope=delta["scope"],
                        slot=delta["slot"],
                        operation=delta["operation"],
                        value=delta["value"],
                        batch_id=delta["batch_id"],
                    )
                )
            chapter.active_archive_revision_id = revision.id
            chapter.archive_status = "complete"
        db.flush()
        # Recompute fingerprints in story order after every ID has changed.
        # Each earlier archive is already active when the next chapter's prior
        # state is calculated, exactly like live extraction.
        for chapter in sorted(chapters_by_source.values(), key=lambda row: (row.index, row.id)):
            if not chapter.active_archive_revision_id:
                continue
            revision = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
            if revision is None:
                raise ProjectPackageError("imported archive revision is missing")
            fingerprint = archive_input_fingerprint(chapter)
            revision.input_fingerprint = fingerprint
            chapter.archive_input_fingerprint = fingerprint
        rebuild_book_projection(db, book.id)
        rebuild_book_search_index(db, book.id)
        db.commit()
        db.refresh(book)
        return book, warnings
    except Exception:
        db.rollback()
        raise
