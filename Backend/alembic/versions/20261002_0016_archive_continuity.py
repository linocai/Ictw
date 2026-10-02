"""Persist source-addressable archive-v2.2 continuity classifications."""
from alembic import op
import sqlalchemy as sa

revision = "20261002_0016"
down_revision = "20260929_0015"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("chapter_archive_revisions", sa.Column("continuity", sa.JSON(), nullable=True))


def downgrade():
    connection = op.get_bind()
    if connection.execute(sa.text(
        "SELECT 1 FROM chapter_archive_revisions WHERE contract_version = 'archive-v2.2' LIMIT 1"
    )).first() is not None:
        raise RuntimeError("archive-v2.2 data exists; preserve it in a backup before any destructive downgrade")
    op.drop_column("chapter_archive_revisions", "continuity")
