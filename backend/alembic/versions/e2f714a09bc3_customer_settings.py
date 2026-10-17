"""Versioned private customer preferences and contact details."""
from alembic import op
import sqlalchemy as sa

revision = "e2f714a09bc3"
down_revision = "d9e4b82013c7"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("customers", sa.Column("profile_revision", sa.Integer(), nullable=False, server_default="0"))
    op.create_table("customer_settings",
        sa.Column("customer_id", sa.String(100), sa.ForeignKey("customers.id"), primary_key=True),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("customized", sa.Boolean(), nullable=False),
        sa.Column("default_vehicle_id", sa.String(36), sa.ForeignKey("vehicles.id"), nullable=True),
        sa.Column("default_estimate_discipline", sa.String(20), nullable=False),
        sa.Column("home_tab", sa.String(20), nullable=False))
    if op.get_bind().dialect.name == "postgresql":
        op.execute('ALTER TABLE customer_settings ENABLE ROW LEVEL SECURITY')
        for role in ("anon", "authenticated", "PUBLIC"):
            condition = "TRUE" if role == "PUBLIC" else f"EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}')"
            op.execute(sa.text(f"DO $$ BEGIN IF {condition} THEN REVOKE ALL ON customer_settings FROM {role}; END IF; END $$"))


def downgrade():
    op.drop_table("customer_settings")
    with op.batch_alter_table("customers") as batch:
        batch.drop_column("profile_revision")
