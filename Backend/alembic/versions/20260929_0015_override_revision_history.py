"""Keep per-book override revisions across deletion and recreation."""
from alembic import op
import sqlalchemy as sa
from app.migration_safety import require_destructive_downgrade_authorization

revision = "20260929_0015"
down_revision = "20260923_0014"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("book_override_revisions",
        sa.Column("book_id", sa.String(36), sa.ForeignKey("books.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("kind", sa.String(32), primary_key=True),
        sa.Column("agent_role", sa.String(32), primary_key=True),
        sa.Column("last_revision", sa.Integer(), nullable=False))


def downgrade():
    require_destructive_downgrade_authorization(op.get_bind(), revision=revision)
    op.drop_table("book_override_revisions")
