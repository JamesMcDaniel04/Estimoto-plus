"""Optional PostgreSQL proof using an isolated schema in a disposable local DB."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
from uuid import uuid4

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from estimoto_plus.app import create_app
from estimoto_plus.config import Settings
from estimoto_plus.models import Base


def test_postgres_settings_upgrade_private_acl_and_concurrent_editors(tmp_path, monkeypatch):
    supplied = os.getenv('PLUS_TEST_POSTGRES_URL')
    if not supplied:
        pytest.skip('PLUS_TEST_POSTGRES_URL is needed for real PostgreSQL proof')
    url = make_url(supplied)
    if url.host not in (None, 'localhost', '127.0.0.1') or 'test' not in (url.database or ''):
        pytest.fail('Use a local disposable test database')
    schema = 'plus_settings_test_' + uuid4().hex
    admin = create_engine(url)
    with admin.begin() as db:
        db.execute(text(f'CREATE SCHEMA "{schema}"'))
    scoped = url.update_query_dict({'options': f'-csearch_path={schema}'})
    engine = create_engine(scoped)
    app = None
    try:
        # Recreate the pre-settings schema without running older migrations that
        # intentionally address public tables in the original deployment.
        Base.metadata.create_all(engine)
        with engine.begin() as db:
            db.execute(text('DROP TABLE customer_settings'))
            db.execute(text('ALTER TABLE customers DROP COLUMN profile_revision'))
            db.execute(text("INSERT INTO customers (id,email,name,phone,postal_code,contact_preference,demo) VALUES ('customer','qa@example.test','Preserved','','80202','email',false)"))
            # Exercise revocation against actual inherited privileges rather
            # than relying on PostgreSQL's already-private table defaults.
            db.execute(text(f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{schema}" GRANT SELECT ON TABLES TO PUBLIC'))
            for role in ('anon', 'authenticated'):
                if db.scalar(text('SELECT 1 FROM pg_roles WHERE rolname=:role'), {'role': role}):
                    db.execute(text(f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{schema}" GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO {role}'))
        monkeypatch.setenv('DATABASE_URL', scoped.render_as_string(hide_password=False))
        root = Path(__file__).resolve().parents[1]
        config = Config(str(root / 'alembic.ini'))
        config.set_main_option('script_location', str(root / 'alembic'))
        command.stamp(config, 'd9e4b82013c7')
        command.upgrade(config, 'head')
        with engine.connect() as db:
            assert db.execute(text('SELECT name,profile_revision FROM customers')).one() == ('Preserved', 0)
            assert db.scalar(text('SELECT relrowsecurity FROM pg_class WHERE oid=\'customer_settings\'::regclass')) is True
            public_grants = db.scalar(text("SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) acl WHERE c.oid='customer_settings'::regclass AND acl.grantee=0"))
            assert public_grants == 0
            for role in ('anon', 'authenticated'):
                if db.scalar(text('SELECT 1 FROM pg_roles WHERE rolname=:role'), {'role': role}):
                    for privilege in ('SELECT', 'INSERT', 'UPDATE', 'DELETE'):
                        assert db.scalar(text("SELECT has_table_privilege(:role,'customer_settings',:privilege)"), {'role': role, 'privilege': privilege}) is False
        settings = Settings(database_url=scoped.render_as_string(hide_password=False), environment='development',
                            photo_dir=str(tmp_path / 'photos'), worker_enabled=False)
        app = create_app(settings, auth_verifier=lambda _: {
            'id': 'customer', 'email': 'qa@example.test', 'email_confirmed_at': 'confirmed'})
        with TestClient(app) as client:
            headers = {'Authorization': 'Bearer test-only'}
            body = {'expected_revision': 0, 'default_vehicle_id': None,
                    'default_estimate_discipline': 'collision', 'home_tab': 'repairs'}
            with ThreadPoolExecutor(max_workers=8) as pool:
                saves = list(pool.map(lambda _: client.put('/v1/settings', headers=headers, json=body), range(8)))
            assert sorted(r.status_code for r in saves) == [200] + [409] * 7
            with ThreadPoolExecutor(max_workers=8) as pool:
                edits = list(pool.map(lambda i: client.put('/v1/profile', headers=headers,
                    json={'expected_revision': 0, 'name': f'Editor {i}'}), range(8)))
            assert sorted(r.status_code for r in edits) == [200] + [409] * 7
            reset = client.delete('/v1/settings?expected_revision=1', headers=headers)
            assert reset.status_code == 200 and reset.json()['revision'] == 2
            assert client.put('/v1/settings', headers=headers, json=body).status_code == 409
            assert client.get('/v1/profile', headers=headers).json()['revision'] == 1
        command.downgrade(config, 'd9e4b82013c7')
        with engine.connect() as db:
            assert db.scalar(text("SELECT to_regclass('customer_settings')")) is None
            assert db.scalar(text("SELECT name FROM customers WHERE id='customer'")).startswith('Editor ')
        command.upgrade(config, 'head')
    finally:
        if app is not None:
            app.state.engine.dispose()
        engine.dispose()
        with admin.begin() as db:
            db.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin.dispose()
