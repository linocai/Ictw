from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from app.auth import require_token
from app.config import get_settings
import app.db as db_module
from app.models import Chapter, JobRun
from app.models.entities import utc_now
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
        run.phase = "failed"
        run.error_code = "interrupted"
        run.error_message = "服务重启，任务中断"
        run.finished_at = utc_now()
    chapters = db.scalars(select(Chapter).where(Chapter.status.in_(["writing", "extracting"]))).all()
    for chapter in chapters:
        chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
    if runs or chapters:
        db.commit()


def create_app() -> FastAPI:
    app = FastAPI(title="LinoI API", version="1.3.2", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    prefix = get_settings().api_prefix
    deps = [Depends(require_token)]

    @app.get(f"{prefix}/health", dependencies=deps)
    def health() -> dict[str, str]:
        return {"status": "ok", "version": "1.3.2"}

    app.include_router(books.router, prefix=prefix, dependencies=deps)
    app.include_router(characters.router, prefix=prefix, dependencies=deps)
    app.include_router(chapters.router, prefix=prefix, dependencies=deps)
    app.include_router(settings.router, prefix=prefix, dependencies=deps)
    return app


app = create_app()
