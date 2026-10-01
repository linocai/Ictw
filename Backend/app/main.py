from __future__ import annotations

from contextlib import asynccontextmanager
import logging
import re

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exception_handlers import http_exception_handler
from fastapi.responses import JSONResponse
from sqlalchemy import select, text
from sqlalchemy.exc import SQLAlchemyError

from app.auth import require_token
from app.config import get_settings
import app.db as db_module
from app.models import Chapter, ChapterArchiveRevision, ChapterDraftCandidate, JobRun
from app.models.entities import utc_now, uuid_str
from app.llm.factory import LLMConfigurationError
from app.routers import books, chapters, characters, settings
from app.services.personas import seed_defaults
from app.services.content_revisions import bump_content_revision

# Single source of truth for the number health reports; deployment verification
# reads it back to confirm the running build. `EXPECTED_ALEMBIC_HEAD` is
# asserted against the real migration head by the test suite, so it cannot
# drift silently.
APP_VERSION = "2.3.4"
EXPECTED_ALEMBIC_HEAD = "20260929_0015"
logger = logging.getLogger(__name__)


def _sop_request_stage(route: str, method: str) -> str:
    if method == "GET":
        return "unknown"
    if "/accept" in route:
        return "accepting"
    if "/check" in route or "/checker/" in route:
        return "checking"
    if "/archive" in route or "/extract" in route:
        return "extracting"
    if "/write" in route:
        return "preflight"
    return "unknown"


def _is_sop_request(path: str, prefix: str) -> bool:
    return path.startswith(f"{prefix}/chapters/") and not path.endswith("/inspirations")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db_module.init_db()
    db = db_module.SessionLocal()
    try:
        seed_defaults(db)
        recover_interrupted_chapters(db)
        yield
    finally:
        db.close()


def recover_interrupted_chapters(db) -> None:
    runs = db.scalars(select(JobRun).where(JobRun.phase.notin_(["done", "failed", "cancelled"]))).all()
    for run in runs:
        interrupted_phase = run.phase
        roles = {
            "selecting_memory": "memory_selector", "writing": "writer",
            "validating": "writer", "checking": "checker", "extracting": "extractor",
        }
        context = dict(run.error_context) if isinstance(run.error_context, dict) else {}
        context["interrupted_phase"] = interrupted_phase
        if interrupted_phase in roles:
            context["agent_role"] = roles[interrupted_phase]
        context["failure_stage"] = {
            "selecting_memory": "selecting_memory", "writing": "writing",
            "validating": "validating", "checking": "checking", "extracting": "extracting",
        }.get(interrupted_phase, "extracting" if run.kind == "extract" else "preflight")
        if run.kind == "extract" and run.archive_revision_id:
            revision = db.get(ChapterArchiveRevision, run.archive_revision_id)
            chapter = db.get(Chapter, run.chapter_id)
            if chapter is not None and chapter.status == "finalized":
                context["manuscript_state"] = "accepted"
                run.phase, run.error_code, run.error_message = "failed", "interrupted", "服务重启，归档任务中断"
                if revision is not None and revision.status in {"pending", "extracting"}:
                    revision.status, revision.error_code, revision.error_message = "failed", "interrupted", "服务重启，归档任务中断"
                    revision.finished_at = utc_now()
                recovered_archive_status = "complete" if chapter.active_archive_revision_id else "failed"
                if chapter.archive_status != recovered_archive_status:
                    chapter.archive_status = recovered_archive_status
                    bump_content_revision(chapter)
            else:
                context["manuscript_state"] = "unknown"
                run.phase, run.error_code, run.error_message = "cancelled", "archive_reopened", "章节已重开，归档任务已取消"
                if revision is not None and revision.status in {"pending", "extracting"}:
                    revision.status, revision.error_code, revision.error_message = "stale", "archive_reopened", "章节已重开，归档结果已失效"
                    revision.is_active = False
                    revision.finished_at = utc_now()
            # The currentness contract compares this stamp with chapter.updated_at.
            # Flush archive recovery first, just as the Writer branch does below.
            run.error_context = dict(context)
            db.flush()
            run.finished_at = utc_now()
            continue
        chapter = db.get(Chapter, run.chapter_id)
        if chapter is not None and chapter.status in {"writing", "extracting"}:
            chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
            bump_content_revision(chapter)
            # Stamp the JobRun after the authoritative visible recovery state.
            db.flush()
        if chapter is None:
            context["manuscript_state"] = "unknown"
        elif chapter.status == "finalized":
            context["manuscript_state"] = "accepted"
        elif context["failure_stage"] == "checking" and run.candidate_id and isinstance(run.input_snapshot, dict) and isinstance(run.input_snapshot.get("draft"), dict) and run.input_snapshot["draft"].get("source") == "candidate" and db.get(ChapterDraftCandidate, run.candidate_id) is not None:
            context["manuscript_state"] = "generated_candidate_retained"
        else:
            context["manuscript_state"] = "unchanged"
        run.error_context = dict(context)
        run.phase = "failed"
        run.error_code = "interrupted"
        run.error_message = "服务重启，任务中断"
        run.finished_at = utc_now()
    if runs:
        db.commit()


def create_app() -> FastAPI:
    # Both clients are native apps, so no browser origin ever needs CORS, and
    # the schema is not public: the interactive docs and openapi.json used to
    # be readable without a token.
    app = FastAPI(
        title="LinoI API",
        version=APP_VERSION,
        lifespan=lifespan,
        openapi_url=None,
        docs_url=None,
        redoc_url=None,
    )

    prefix = get_settings().api_prefix

    @app.middleware("http")
    async def sop_request_reference(request: Request, call_next):
        if not _is_sop_request(request.url.path, prefix):
            return await call_next(request)
        request_id = uuid_str()
        request.state.sop_request_id = request_id
        try:
            response = await call_next(request)
        except Exception as exc:
            route_obj = request.scope.get("route")
            route = str(getattr(route_obj, "path", "unmatched"))
            logger.warning(
                "sop_request_failed request_id=%s method=%s route=%s stage=%s exception_type=%s",
                request_id, request.method, route, _sop_request_stage(route, request.method), type(exc).__name__,
            )
            raise
        response.headers["X-Request-ID"] = request_id
        if response.status_code >= 400:
            route_obj = request.scope.get("route")
            route = str(getattr(route_obj, "path", "unmatched"))
            logger.warning(
                "sop_http_failure request_id=%s method=%s route=%s stage=%s http_status=%s",
                request_id, request.method, route, _sop_request_stage(route, request.method), response.status_code,
            )
        return response

    @app.exception_handler(Exception)
    async def sop_unexpected_error(request: Request, exc: Exception):
        if not _is_sop_request(request.url.path, prefix):
            return JSONResponse(status_code=500, content={"detail": "Internal Server Error"})
        request_id = getattr(request.state, "sop_request_id", None)
        route_obj = request.scope.get("route")
        route = str(getattr(route_obj, "path", "unmatched"))
        stage = _sop_request_stage(route, request.method)
        return JSONResponse(
            status_code=500,
            headers={"X-Request-ID": request_id} if request_id else None,
            content={"detail": {"code": "request_failed", "message": "请求执行异常，结果尚待确认；请刷新章节状态", "error_context": {
                "request_id": request_id, "failure_stage": stage, "manuscript_state": "unknown",
            }}},
        )

    @app.exception_handler(HTTPException)
    async def sop_http_error(request: Request, exc: HTTPException):
        if not _is_sop_request(request.url.path, prefix) or not isinstance(exc.detail, dict):
            return await http_exception_handler(request, exc)
        detail = dict(exc.detail)
        context = dict(detail.get("error_context")) if isinstance(detail.get("error_context"), dict) else {}
        request_id = getattr(request.state, "sop_request_id", None)
        if request_id:
            context["request_id"] = request_id
        route_obj = request.scope.get("route")
        route = str(getattr(route_obj, "path", "unmatched"))
        context.setdefault("failure_stage", _sop_request_stage(route, request.method))
        context.setdefault("manuscript_state", "unknown")
        detail["error_context"] = context
        code = detail.get("code")
        safe_code = code if isinstance(code, str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) else "unknown"
        logger.warning(
            "sop_request_rejected request_id=%s method=%s route=%s stage=%s code=%s http_status=%s",
            request_id or "none", request.method, route, context["failure_stage"], safe_code, exc.status_code,
        )
        return JSONResponse(status_code=exc.status_code, content={"detail": detail}, headers=exc.headers)

    @app.exception_handler(LLMConfigurationError)
    async def llm_configuration_error(_request: Request, exc: LLMConfigurationError) -> JSONResponse:
        return JSONResponse(
            status_code=409,
            content={
                "detail": {
                    "code": exc.code,
                    "message": exc.message,
                    "details": {"agent_role": exc.agent_role},
                }
            },
        )

    deps = [Depends(require_token)]

    @app.get(f"{prefix}/health", dependencies=deps)
    def health() -> dict[str, str]:
        # Release gating waits on this endpoint before running the public
        # checks, so it must actually touch the database it will serve. A
        # static literal returned 200 for an empty database created against
        # the wrong working directory, and for a schema that never ran the
        # pending migration.
        db = db_module.SessionLocal()
        try:
            applied = db.scalar(text("SELECT version_num FROM alembic_version"))
        except SQLAlchemyError:
            raise HTTPException(
                status_code=503,
                detail={"code": "database_unavailable", "message": "数据库不可用或未迁移"},
            )
        finally:
            db.close()
        if applied != EXPECTED_ALEMBIC_HEAD:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "schema_out_of_date",
                    "message": "数据库结构与本版本不一致，请先执行 alembic upgrade head",
                    "details": {"expected": EXPECTED_ALEMBIC_HEAD, "applied": applied},
                },
            )
        return {"status": "ok", "version": APP_VERSION}

    app.include_router(books.router, prefix=prefix, dependencies=deps)
    app.include_router(characters.router, prefix=prefix, dependencies=deps)
    app.include_router(chapters.router, prefix=prefix, dependencies=deps)
    app.include_router(settings.router, prefix=prefix, dependencies=deps)
    return app


app = create_app()
