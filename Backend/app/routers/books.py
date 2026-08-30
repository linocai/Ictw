from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Response, status
from sqlalchemy import func, or_, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

import json

from app.db import get_db
from app.models import (
    AgentModelBinding, AgentPersona, Book, BookAgentModelBinding, BookAgentPersona,
    Chapter, ChapterArchiveRevision, Character, CharacterEvent, LLMProfile, SearchDocument,
)
from app.models.entities import utc_now
from app.schemas.book import BookCreate, BookExportDataRead, BookPatch, BookRead, ProjectImportRead
from app.schemas.settings import (
    AgentModelBindingValueRead, BookAgentModelBindingPut, BookAgentModelBindingRead,
    BookAgentPersonaPut, BookAgentPersonaRead,
)
from app.schemas.search import SearchResponse
from app.services.archive_v2 import active_archive_revision
from app.services.personas import AGENT_ROLES, DEFAULT_PERSONAS, PROGRAM_PROTOCOLS
from app.services.write_ownership import cancel_local_writer_jobs, chapters_for_book, invalidate_writer_inputs
from app.services.content_revisions import (
    bump_content_revision,
    raise_write_conflict,
    require_absent_revision,
    require_matching_revision,
)
from app.services.model_capabilities import (
    effective_binding_settings, requires_bounded_non_thinking, resolve_capabilities,
    sanitized_settings, sanitized_temperature, temperature_sendable,
)
from app.services.project_packages import (
    PROJECT_MEDIA_TYPE,
    ProjectPackageError,
    export_project_package,
    import_project_package,
)
from app.services.search_index import rebuild_book_search_index, snippet_for_query

router = APIRouter(tags=["books"])


def _book_persona_response(
    role: str,
    override: BookAgentPersona | None,
    global_persona: AgentPersona | None,
) -> dict[str, object]:
    global_value = global_persona.system_prompt if global_persona is not None else DEFAULT_PERSONAS[role]
    if override is not None:
        source, effective = "book", override.editable_persona
    elif global_persona is not None:
        source, effective = "global", global_value
    else:
        source, effective = "default", global_value
    return {
        "agent_role": role,
        "source": source,
        "book_persona": override.editable_persona if override is not None else None,
        "global_persona": global_value,
        "default_persona": DEFAULT_PERSONAS[role],
        "effective_persona": effective,
        "program_protocol": PROGRAM_PROTOCOLS[role],
        "updated_at": override.updated_at if override is not None else None,
        "content_revision": override.content_revision if override is not None else None,
    }


def _binding_value(binding, profile: LLMProfile | None) -> dict[str, object]:
    capabilities = resolve_capabilities(profile.model_name if profile else None, profile.base_url if profile else None)
    thinking, effort = effective_binding_settings(binding, profile)
    if requires_bounded_non_thinking(binding.agent_role) and profile is not None and capabilities.thinking_can_disable:
        thinking, effort = False, None
    return {
        "llm_profile_id": binding.llm_profile_id,
        "thinking_enabled": binding.thinking_enabled,
        "reasoning_effort": binding.reasoning_effort,
        "temperature": binding.temperature,
        "effective_thinking_enabled": thinking,
        "effective_reasoning_effort": effort,
        "effective_temperature": sanitized_temperature(binding.temperature, thinking, capabilities),
        "content_revision": getattr(binding, "content_revision", None),
    }


def _book_binding_response(
    role: str,
    override: BookAgentModelBinding | None,
    global_binding: AgentModelBinding | None,
    db: Session,
) -> dict[str, object]:
    # seed_defaults creates all bindings, but keep a deterministic empty
    # representation for a database created outside the application lifespan.
    global_binding = global_binding or AgentModelBinding(agent_role=role, llm_profile_id=None)
    global_profile = db.get(LLMProfile, global_binding.llm_profile_id) if global_binding.llm_profile_id else None
    override_profile = db.get(LLMProfile, override.llm_profile_id) if override and override.llm_profile_id else None
    effective = override if override is not None and override_profile is not None else global_binding
    effective_profile = override_profile if effective is override else global_profile
    capabilities = resolve_capabilities(
        effective_profile.model_name if effective_profile else None,
        effective_profile.base_url if effective_profile else None,
    )
    return {
        "agent_role": role,
        "source": "book" if effective is override else ("global" if global_binding.llm_profile_id else "default"),
        "book_binding": _binding_value(override, override_profile) if override is not None else None,
        "global_binding": _binding_value(global_binding, global_profile),
        "effective_binding": _binding_value(effective, effective_profile),
        "capabilities": capabilities.as_dict(),
        "content_revision": override.content_revision if override is not None else None,
    }


def _validated_book_binding_values(role: str, payload: BookAgentModelBindingPut, db: Session) -> dict[str, object]:
    profile = db.get(LLMProfile, payload.llm_profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="profile not found")
    capabilities = resolve_capabilities(profile.model_name, profile.base_url)
    thinking, effort, temperature = payload.thinking_enabled, payload.reasoning_effort, payload.temperature
    if requires_bounded_non_thinking(role):
        role_label = "Extractor" if role == "extractor" else "灵感创造师"
        if not capabilities.thinking_can_disable:
            raise HTTPException(status_code=422, detail=f"{role_label} 需要绑定支持关闭思考的模型")
        if thinking is True or effort is not None:
            raise HTTPException(status_code=422, detail=f"{role_label} 固定关闭思考")
        thinking, effort = False, None
    if capabilities.family == "unknown" and (thinking is not None or effort is not None):
        raise HTTPException(status_code=422, detail="此模型未声明可调思考参数")
    if capabilities.thinking_required and thinking is False:
        raise HTTPException(status_code=422, detail="此模型的思考模式不能关闭")
    if effort is not None and effort not in capabilities.reasoning_effort_levels:
        raise HTTPException(status_code=422, detail="该思考强度不受当前模型支持")
    if capabilities.thinking_toggle_supported and effort is not None and thinking is not True:
        raise HTTPException(status_code=422, detail="启用思考后才能选择思考强度")
    if temperature is not None:
        if not 0.0 <= temperature <= 2.0:
            raise HTTPException(status_code=422, detail="temperature 需在 0.0～2.0 之间")
        effective_thinking = True if capabilities.thinking_required else thinking
        if not temperature_sendable(effective_thinking, capabilities):
            raise HTTPException(status_code=422, detail="此模型不支持调整 temperature")
    if capabilities.thinking_required and thinking is True:
        thinking = None
    thinking, effort = sanitized_settings(thinking, effort, capabilities)
    return {
        "llm_profile_id": profile.id,
        "thinking_enabled": thinking,
        "reasoning_effort": effort,
        "temperature": sanitized_temperature(temperature, thinking, capabilities),
    }


def _require_book(db: Session, book_id: str) -> Book:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    return book


@router.get("/books/{book_id}/agent-personas", response_model=list[BookAgentPersonaRead])
def list_book_personas(book_id: str, db: Session = Depends(get_db)) -> list[dict[str, object]]:
    _require_book(db, book_id)
    overrides = {
        item.agent_role: item
        for item in db.scalars(select(BookAgentPersona).where(BookAgentPersona.book_id == book_id)).all()
    }
    globals_by_role = {item.agent_role: item for item in db.scalars(select(AgentPersona)).all()}
    return [_book_persona_response(role, overrides.get(role), globals_by_role.get(role)) for role in AGENT_ROLES]


@router.get("/books/{book_id}/agent-personas/{agent_role}", response_model=BookAgentPersonaRead)
def get_book_persona(book_id: str, agent_role: str, db: Session = Depends(get_db)) -> dict[str, object]:
    _require_book(db, book_id)
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    override = db.scalars(select(BookAgentPersona).where(
        BookAgentPersona.book_id == book_id, BookAgentPersona.agent_role == agent_role
    )).first()
    return _book_persona_response(agent_role, override, db.get(AgentPersona, agent_role))


@router.put("/books/{book_id}/agent-personas/{agent_role}", response_model=BookAgentPersonaRead)
def put_book_persona(
    book_id: str,
    agent_role: str,
    payload: BookAgentPersonaPut,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> dict[str, object]:
    _require_book(db, book_id)
    if agent_role not in AGENT_ROLES:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="agent role not found")
    override = db.scalars(
        select(BookAgentPersona).where(
            BookAgentPersona.book_id == book_id,
            BookAgentPersona.agent_role == agent_role,
        )
    ).first()
    if override is None:
        submitted = require_absent_revision(if_match)
        try:
            with db.begin_nested():
                override = BookAgentPersona(book_id=book_id, agent_role=agent_role, editable_persona=payload.value)
                db.add(override)
                db.flush()
        except IntegrityError:
            db.expire_all()
            override = db.scalars(select(BookAgentPersona).where(
                BookAgentPersona.book_id == book_id, BookAgentPersona.agent_role == agent_role
            )).first()
            if override is None:
                raise
            if submitted is not None:
                raise_write_conflict(
                    resource_type="book_agent_persona",
                    resource_id=override.id,
                    submitted_revision=submitted,
                    current_revision=override.content_revision,
                )
            override.editable_persona = payload.value
            bump_content_revision(override)
    else:
        require_matching_revision(
            override, if_match, resource_type="book_agent_persona", resource_id=override.id, db=db
        )
        override.editable_persona = payload.value
        bump_content_revision(override)
    db.commit()
    db.refresh(override)
    return _book_persona_response(agent_role, override, db.get(AgentPersona, agent_role))


@router.delete("/books/{book_id}/agent-personas/{agent_role}", status_code=status.HTTP_204_NO_CONTENT)
def delete_book_persona(
    book_id: str, agent_role: str, db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    _require_book(db, book_id)
    if agent_role not in AGENT_ROLES:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="agent role not found")
    override = db.scalars(
        select(BookAgentPersona).where(
            BookAgentPersona.book_id == book_id,
            BookAgentPersona.agent_role == agent_role,
        )
    ).first()
    if override is not None:
        require_matching_revision(
            override, if_match, resource_type="book_agent_persona", resource_id=override.id, db=db
        )
        db.delete(override)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def book_read(db: Session, book: Book) -> BookRead:
    chapter_count = db.scalar(select(func.count()).select_from(Chapter).where(Chapter.book_id == book.id)) or 0
    character_count = db.scalar(select(func.count()).select_from(Character).where(Character.book_id == book.id)) or 0
    data = BookRead.model_validate(book)
    data.chapter_count = chapter_count
    data.character_count = character_count
    data.archive_pending_count = db.scalar(
        select(func.count()).select_from(Chapter).where(
            Chapter.book_id == book.id,
            Chapter.archive_status.in_(("pending", "extracting")),
        )
    ) or 0
    data.archive_attention_count = db.scalar(
        select(func.count()).select_from(Chapter).where(
            Chapter.book_id == book.id,
            Chapter.archive_status.in_(("stale", "partial", "failed")),
            # New editable chapters start stale before any archive exists.
            # Attention means a real archive lifecycle has since become
            # incomplete or invalid, not merely "not archived yet".
            select(ChapterArchiveRevision.id)
            .where(ChapterArchiveRevision.chapter_id == Chapter.id)
            .exists(),
        )
    ) or 0
    return data


@router.get("/books", response_model=list[BookRead])
def list_books(db: Session = Depends(get_db)) -> list[BookRead]:
    books = db.scalars(select(Book).order_by(Book.last_opened_at.desc().nullslast(), Book.updated_at.desc())).all()
    return [book_read(db, book) for book in books]


@router.post("/books", response_model=BookRead, status_code=status.HTTP_201_CREATED)
def create_book(payload: BookCreate, db: Session = Depends(get_db)) -> BookRead:
    book = Book(title=payload.title, world_setting=payload.world_setting, last_opened_at=utc_now())
    db.add(book)
    db.flush()
    rebuild_book_search_index(db, book.id)
    db.commit()
    db.refresh(book)
    return book_read(db, book)


@router.get("/books/{book_id}", response_model=BookRead)
def get_book(book_id: str, db: Session = Depends(get_db)) -> BookRead:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    book.last_opened_at = utc_now()
    db.commit()
    db.refresh(book)
    return book_read(db, book)


@router.patch("/books/{book_id}", response_model=BookRead)
def patch_book(
    book_id: str,
    payload: BookPatch,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> BookRead:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    require_matching_revision(book, if_match, resource_type="book", resource_id=book.id, db=db)
    updates = payload.model_dump(exclude_unset=True)
    for key, value in updates.items():
        # exclude_unset keeps explicitly-sent nulls, and both columns are NOT
        # NULL; assigning one used to surface as a 500 at flush time.
        if value is None:
            continue
        setattr(book, key, value)
    if updates:
        bump_content_revision(book)
    invalidated = invalidate_writer_inputs(db, chapters_for_book(db, book.id)) if "world_setting" in updates else []
    rebuild_book_search_index(db, book.id)
    db.commit()
    cancel_local_writer_jobs(invalidated)
    db.refresh(book)
    return book_read(db, book)


@router.delete("/books/{book_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_book(
    book_id: str, db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    book = db.get(Book, book_id)
    if book is not None:
        require_matching_revision(book, if_match, resource_type="book", resource_id=book.id, db=db)
        db.delete(book)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/books/{book_id}/project-export")
def export_book_project(book_id: str, db: Session = Depends(get_db)) -> Response:
    """Return a complete, author-visible, portable ICTW project package."""
    book = _require_book(db, book_id)
    try:
        payload = export_project_package(db, book)
    except ProjectPackageError as exc:
        raise HTTPException(status_code=422, detail={"code": "project_export_invalid", "message": str(exc)}) from exc
    return Response(
        payload,
        media_type=PROJECT_MEDIA_TYPE,
        headers={"Content-Disposition": 'attachment; filename="ICTW-project.ictwbook"'},
    )


@router.post("/books/project-import", response_model=ProjectImportRead, status_code=status.HTTP_201_CREATED)
async def import_book_project(request: Request, db: Session = Depends(get_db)) -> dict[str, object]:
    """Restore a package as a new book; existing books are never overwritten."""
    try:
        book, warnings = import_project_package(db, await request.body())
    except ProjectPackageError as exc:
        raise HTTPException(status_code=422, detail={"code": "project_import_invalid", "message": str(exc)}) from exc
    return {"book_id": book.id, "title": book.title, "warnings": warnings}


@router.get("/books/{book_id}/export-data", response_model=BookExportDataRead)
def export_book_data(book_id: str, db: Session = Depends(get_db)) -> dict[str, object]:
    """One aggregate read for client-side prose export composition.

    It intentionally contains only author-visible fields needed by the legacy
    plain/Markdown and per-chapter file options; clients no longer need a GET
    for every chapter just to prepare an export.
    """
    book = _require_book(db, book_id)
    chapters = db.scalars(
        select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index, Chapter.id)
    ).all()
    characters = db.scalars(
        select(Character).where(Character.book_id == book_id).order_by(Character.created_at, Character.id)
    ).all()
    return {
        "book_id": book.id,
        "title": book.title,
        "world_setting": book.world_setting,
        "chapters": [
            {
                "id": chapter.id,
                "index": chapter.index,
                "title": chapter.title,
                "draft_text": chapter.draft_text,
                "status": chapter.status,
            }
            for chapter in chapters
        ],
        "characters": [
            {
                "id": character.id,
                "name": character.name,
                "role": character.role,
                "fixed_profile": character.fixed_profile,
            }
            for character in characters
        ],
    }


@router.get("/search", response_model=SearchResponse)
def search(
    q: str = Query(min_length=1, max_length=200),
    book_id: str | None = Query(default=None),
    limit: int = Query(default=30, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
) -> dict[str, object]:
    query = q.strip()
    if not query:
        raise HTTPException(status_code=422, detail="搜索词不能为空")
    if book_id is not None:
        if db.get(Book, book_id) is None:
            raise HTTPException(status_code=404, detail="book not found")
    if len(query) >= 3:
        # Trigram FTS gives Chinese and Latin substring matching without turning
        # user input into SQL wildcards. Quoting the phrase also makes FTS
        # operators in the query literal author text.
        match_query = '"' + query.replace('"', '""') + '"'
        book_filter = " AND d.book_id = :book_id" if book_id is not None else ""
        params = {"match_query": match_query, "book_id": book_id, "limit": limit, "offset": offset}
        total = db.execute(text(f"""
            SELECT count(*)
            FROM search_documents_fts
            JOIN search_documents AS d ON d.rowid = search_documents_fts.rowid
            WHERE search_documents_fts MATCH :match_query{book_filter}
        """), params).scalar_one()
        result_ids = list(db.execute(text(f"""
            SELECT d.id
            FROM search_documents_fts
            JOIN search_documents AS d ON d.rowid = search_documents_fts.rowid
            WHERE search_documents_fts MATCH :match_query{book_filter}
            ORDER BY bm25(search_documents_fts), d.updated_at DESC, d.id
            LIMIT :limit OFFSET :offset
        """), params).scalars())
        documents = db.scalars(select(SearchDocument).where(SearchDocument.id.in_(result_ids))).all() if result_ids else []
        by_id = {document.id: document for document in documents}
        rows = [by_id[result_id] for result_id in result_ids if result_id in by_id]
    else:
        # FTS5 trigram intentionally has no tokens shorter than three Unicode
        # characters. Keep names such as “小雨” searchable with a correctly
        # escaped fallback; %, _ and backslash are always literal here.
        escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        pattern = f"%{escaped}%"
        filters = (
            or_(
                SearchDocument.title.ilike(pattern, escape="\\"),
                SearchDocument.body.ilike(pattern, escape="\\"),
            ),
        )
        if book_id is not None:
            filters = (*filters, SearchDocument.book_id == book_id)
        total = db.scalar(select(func.count()).select_from(SearchDocument).where(*filters)) or 0
        rows = db.scalars(
            select(SearchDocument)
            .where(*filters)
            .order_by(SearchDocument.updated_at.desc(), SearchDocument.id)
            .offset(offset)
            .limit(limit)
        ).all()
    return {
        "query": query,
        "total": total,
        "items": [
            {
                "id": row.id,
                "book_id": row.book_id,
                "chapter_id": row.chapter_id,
                "character_id": row.character_id,
                "result_type": row.result_type,
                "title": row.title,
                "snippet": snippet_for_query(
                    row.body if query.casefold() in row.body.casefold() else row.title,
                    query,
                ),
            }
            for row in rows
        ],
    }


@router.get("/books/{book_id}/agent-model-bindings", response_model=list[BookAgentModelBindingRead])
def list_book_model_bindings(book_id: str, db: Session = Depends(get_db)) -> list[dict[str, object]]:
    _require_book(db, book_id)
    overrides = {
        item.agent_role: item
        for item in db.scalars(select(BookAgentModelBinding).where(BookAgentModelBinding.book_id == book_id)).all()
    }
    globals_by_role = {item.agent_role: item for item in db.scalars(select(AgentModelBinding)).all()}
    return [_book_binding_response(role, overrides.get(role), globals_by_role.get(role), db) for role in AGENT_ROLES]


@router.get("/books/{book_id}/agent-model-bindings/{agent_role}", response_model=BookAgentModelBindingRead)
def get_book_model_binding(book_id: str, agent_role: str, db: Session = Depends(get_db)) -> dict[str, object]:
    _require_book(db, book_id)
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    override = db.scalars(select(BookAgentModelBinding).where(
        BookAgentModelBinding.book_id == book_id, BookAgentModelBinding.agent_role == agent_role
    )).first()
    return _book_binding_response(agent_role, override, db.get(AgentModelBinding, agent_role), db)


@router.put("/books/{book_id}/agent-model-bindings/{agent_role}", response_model=BookAgentModelBindingRead)
def put_book_model_binding(
    book_id: str,
    agent_role: str,
    payload: BookAgentModelBindingPut,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> dict[str, object]:
    _require_book(db, book_id)
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    override = db.scalars(select(BookAgentModelBinding).where(
        BookAgentModelBinding.book_id == book_id, BookAgentModelBinding.agent_role == agent_role
    )).first()
    values = _validated_book_binding_values(agent_role, payload, db)
    if override is None:
        submitted = require_absent_revision(if_match)
        try:
            with db.begin_nested():
                override = BookAgentModelBinding(book_id=book_id, agent_role=agent_role, **values)
                db.add(override)
                db.flush()
        except IntegrityError:
            db.expire_all()
            override = db.scalars(select(BookAgentModelBinding).where(
                BookAgentModelBinding.book_id == book_id, BookAgentModelBinding.agent_role == agent_role
            )).first()
            if override is None:
                raise
            if submitted is not None:
                raise_write_conflict(
                    resource_type="book_agent_model_binding",
                    resource_id=override.id,
                    submitted_revision=submitted,
                    current_revision=override.content_revision,
                )
            for key, value in values.items():
                setattr(override, key, value)
            bump_content_revision(override)
    else:
        require_matching_revision(
            override, if_match, resource_type="book_agent_model_binding", resource_id=override.id, db=db
        )
        for key, value in values.items():
            setattr(override, key, value)
        bump_content_revision(override)
    db.commit()
    db.refresh(override)
    return _book_binding_response(agent_role, override, db.get(AgentModelBinding, agent_role), db)


@router.delete("/books/{book_id}/agent-model-bindings/{agent_role}", status_code=status.HTTP_204_NO_CONTENT)
def delete_book_model_binding(
    book_id: str,
    agent_role: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    _require_book(db, book_id)
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    override = db.scalars(select(BookAgentModelBinding).where(
        BookAgentModelBinding.book_id == book_id, BookAgentModelBinding.agent_role == agent_role
    )).first()
    if override is not None:
        require_matching_revision(
            override, if_match, resource_type="book_agent_model_binding", resource_id=override.id, db=db
        )
        db.delete(override)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/books/{book_id}/export.txt")
def export_book(book_id: str, db: Session = Depends(get_db)) -> Response:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    chapters = db.scalars(
        select(Chapter).where(Chapter.book_id == book_id, Chapter.status == "finalized").order_by(Chapter.index)
    ).all()
    parts = [book.title, ""]
    for chapter in chapters:
        parts.extend([f"第 {chapter.index} 章 {chapter.title}".strip(), "", chapter.draft_text, ""])
    return Response("\n".join(parts), media_type="text/plain; charset=utf-8")


def _dynamic_value_text(value: object) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False)


@router.get("/books/{book_id}/memories/export.txt")
def export_memories(book_id: str, db: Session = Depends(get_db)) -> Response:
    """导出 Extractor 生成的全部记忆：大事记、章节摘要、人物动态字段与故事线。

    与 `export.txt`（正文导出）互补；这里不含任何章节正文，只含记忆产物，
    章节不限 finalized（long_summary/headline 可被用户手动编辑，编辑结果一并导出）。
    """
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    chapters = db.scalars(select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)).all()
    characters = db.scalars(
        select(Character).where(Character.book_id == book_id).order_by(Character.created_at)
    ).all()
    chapter_order = {chapter.id: chapter.index for chapter in chapters}
    archive_by_chapter = {
        chapter.id: revision
        for chapter in chapters
        if (revision := active_archive_revision(db, chapter)) is not None
    }
    events = db.scalars(select(CharacterEvent).where(CharacterEvent.book_id == book_id)).all()
    events_by_character: dict[str, list[dict[str, object]]] = {}
    for event in events:
        if event.chapter_id in archive_by_chapter:
            continue
        events_by_character.setdefault(event.character_id, []).append({
            "chapter_id": event.chapter_id,
            "event_type": event.event_type,
            "event_text": event.event_text,
            "created_at": event.created_at,
        })
    for chapter_id, revision in archive_by_chapter.items():
        for fact in revision.facts:
            for participant in fact.participants:
                events_by_character.setdefault(participant.character_id, []).append({
                    "chapter_id": chapter_id,
                    "event_type": fact.fact_type,
                    "event_text": fact.fact_text,
                    "created_at": fact.created_at,
                })

    parts = [f"{book.title}——记忆导出", ""]

    parts.append("【大事记】")
    headline_lines: list[str] = []
    for chapter in chapters:
        revision = archive_by_chapter.get(chapter.id)
        headline = revision.facts[0].fact_text if revision is not None and revision.facts else chapter.headline.strip()
        if headline:
            headline_lines.append(f"第 {chapter.index} 章 {chapter.title}：{headline}".strip())
    parts.extend(headline_lines or ["（暂无）"])
    parts.append("")

    parts.append("【章节摘要】")
    summary_blocks: list[str] = []
    for chapter in chapters:
        revision = archive_by_chapter.get(chapter.id)
        canonical_summary = revision.summary.strip() if revision is not None else chapter.long_summary.strip()
        if canonical_summary:
            summary_blocks.extend([f"第 {chapter.index} 章 {chapter.title}".strip(), canonical_summary, ""])
    if summary_blocks:
        parts.extend(summary_blocks)
    else:
        parts.extend(["（暂无）", ""])

    parts.append("【人物记忆】")
    if characters:
        for character in characters:
            header = f"{character.name}（{character.role}）" if character.role.strip() else character.name
            parts.append(header)
            if character.dynamic_fields:
                parts.append("动态字段：")
                for key in sorted(character.dynamic_fields):
                    parts.append(f"  {key}：{_dynamic_value_text(character.dynamic_fields[key])}")
            character_events = sorted(
                events_by_character.get(character.id, []),
                key=lambda event: (chapter_order.get(str(event["chapter_id"]), 0), event["created_at"]),
            )
            if character_events:
                parts.append("故事线：")
                for event in character_events:
                    index = chapter_order.get(str(event["chapter_id"]))
                    prefix = f"第 {index} 章" if index is not None else "（章节已删除）"
                    parts.append(f"  {prefix} [{event['event_type']}] {event['event_text']}")
            if not character.dynamic_fields and not character_events:
                parts.append("（暂无记忆）")
            parts.append("")
    else:
        parts.extend(["（暂无人物）", ""])

    return Response("\n".join(parts), media_type="text/plain; charset=utf-8")
