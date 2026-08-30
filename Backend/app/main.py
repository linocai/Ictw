from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy import select, text
from sqlalchemy.exc import SQLAlchemyError

from app.auth import require_token
from app.config import get_settings
import app.db as db_module
from app.models import Chapter, ChapterArchiveRevision, JobRun
from app.models.entities import utc_now
from app.llm.factory import LLMConfigurationError
from app.routers import books, chapters, characters, settings
from app.services.personas import seed_defaults
from app.services.content_revisions import bump_content_revision

# Single source of truth for the number health reports; deployment verification
# reads it back to confirm the running build. `EXPECTED_ALEMBIC_HEAD` is
# asserted against the real migration head by the test suite, so it cannot
# drift silently.
APP_VERSION = "2.1.0"
EXPECTED_ALEMBIC_HEAD = "20260830_0013"


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
        if run.kind == "extract" and run.archive_revision_id:
            revision = db.get(ChapterArchiveRevision, run.archive_revision_id)
            chapter = db.get(Chapter, run.chapter_id)
            if chapter is not None and chapter.status == "finalized":
                run.phase, run.error_code, run.error_message = "failed", "interrupted", "服务重启，归档任务中断"
                if revision is not None and revision.status in {"pending", "extracting"}:
                    revision.status, revision.error_code, revision.error_message = "failed", "interrupted", "服务重启，归档任务中断"
                    revision.finished_at = utc_now()
                recovered_archive_status = "complete" if chapter.active_archive_revision_id else "failed"
                if chapter.archive_status != recovered_archive_status:
                    chapter.archive_status = recovered_archive_status
                    bump_content_revision(chapter)
            else:
                run.phase, run.error_code, run.error_message = "cancelled", "archive_reopened", "章节已重开，归档任务已取消"
                if revision is not None and revision.status in {"pending", "extracting"}:
                    revision.status, revision.error_code, revision.error_message = "stale", "archive_reopened", "章节已重开，归档结果已失效"
                    revision.is_active = False
                    revision.finished_at = utc_now()
            run.finished_at = utc_now()
            continue
        chapter = db.get(Chapter, run.chapter_id)
        if chapter is not None and chapter.status in {"writing", "extracting"}:
            chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
            bump_content_revision(chapter)
            # Stamp the JobRun after the authoritative visible recovery state.
            db.flush()
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

    prefix = get_settings().api_prefix
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
