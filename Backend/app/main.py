from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import select

from app.auth import require_token
from app.config import get_settings
import app.db as db_module
from app.models import Chapter, ChapterArchiveRevision, JobRun
from app.models.entities import utc_now
from app.llm.factory import LLMConfigurationError
from app.routers import books, chapters, characters, settings
from app.services.personas import seed_defaults


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
                chapter.archive_status = "complete" if chapter.active_archive_revision_id else "failed"
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
            # Stamp the JobRun after the authoritative visible recovery state.
            db.flush()
        run.phase = "failed"
        run.error_code = "interrupted"
        run.error_message = "服务重启，任务中断"
        run.finished_at = utc_now()
    if runs:
        db.commit()


def create_app() -> FastAPI:
    app = FastAPI(title="LinoI API", version="1.8.3", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
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
        return {"status": "ok", "version": "1.8.3"}

    app.include_router(books.router, prefix=prefix, dependencies=deps)
    app.include_router(characters.router, prefix=prefix, dependencies=deps)
    app.include_router(chapters.router, prefix=prefix, dependencies=deps)
    app.include_router(settings.router, prefix=prefix, dependencies=deps)
    return app


app = create_app()
