"""Customer notification feed, email preference and anonymous client error reports."""
from alembic import op
import sqlalchemy as sa

revision = 'a4c1e7b9d2f0'
down_revision = 'd9e4b82013c7'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('customers', sa.Column('notification_emails', sa.Boolean(), nullable=False, server_default=sa.true()))
    op.create_table(
        'customer_notifications',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('customer_id', sa.String(100), sa.ForeignKey('customers.id'), nullable=False),
        sa.Column('kind', sa.String(40), nullable=False),
        sa.Column('title', sa.String(200), nullable=False),
        sa.Column('body', sa.Text(), nullable=False, server_default=''),
        sa.Column('source_kind', sa.String(20), nullable=False),
        sa.Column('source_id', sa.String(36), nullable=True),
        sa.Column('dedupe_key', sa.String(200), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('read_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('email_status', sa.String(20), nullable=False, server_default='pending'),
        sa.Column('email_attempts', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('next_email_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('email_receipt', sa.String(200), nullable=True),
        sa.UniqueConstraint('customer_id', 'dedupe_key'),
    )
    op.create_index('ix_customer_notifications_customer_id', 'customer_notifications', ['customer_id'])
    op.create_index('ix_customer_notifications_email_due', 'customer_notifications', ['email_status', 'next_email_at'])
    op.create_table(
        'client_errors',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('fingerprint', sa.String(64), nullable=False),
        sa.Column('day', sa.String(10), nullable=False),
        sa.Column('platform', sa.String(20), nullable=False),
        sa.Column('app_version', sa.String(40), nullable=False, server_default=''),
        sa.Column('build_number', sa.String(20), nullable=False, server_default=''),
        sa.Column('source_sha', sa.String(40), nullable=False, server_default=''),
        sa.Column('kind', sa.String(100), nullable=False),
        sa.Column('message', sa.String(500), nullable=False, server_default=''),
        sa.Column('stack', sa.Text(), nullable=False, server_default=''),
        sa.Column('occurrences', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('first_seen_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('last_seen_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('fingerprint', 'day'),
    )


def downgrade():
    op.drop_table('client_errors')
    op.drop_index('ix_customer_notifications_email_due', table_name='customer_notifications')
    op.drop_index('ix_customer_notifications_customer_id', table_name='customer_notifications')
    op.drop_table('customer_notifications')
    with op.batch_alter_table('customers') as batch:
        batch.drop_column('notification_emails')
