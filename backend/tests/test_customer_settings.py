"""Customer preferences are private, persistent and protected from stale editors."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sqlite3

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import event

from estimoto_plus.app import create_app
from estimoto_plus.config import Settings
from test_api import clients, create_vehicle, h


DEFAULTS = {"revision": 0, "customized": False, "default_vehicle_id": None,
            "default_estimate_discipline": "pdr", "home_tab": "garage"}


def preferences(revision=0, vehicle=None, **changes):
    return {"expected_revision": revision, "default_vehicle_id": vehicle,
            "default_estimate_discipline": "collision", "home_tab": "estimates", **changes}


def test_settings_read_does_not_create_preferences_and_bootstrap_agrees(clients):
    client, _ = clients
    bootstrap = client.get('/v1/bootstrap', headers=h('alice')).json()
    assert bootstrap.get('settings') == DEFAULTS
    writes = []
    def track(_conn, _cursor, statement, _params, _context, _many):
        if statement.lstrip().upper().startswith(('INSERT', 'UPDATE', 'DELETE')):
            writes.append(statement)
    event.listen(client.app.state.engine, 'before_cursor_execute', track)
    try:
        result = client.get('/v1/settings', headers=h('alice'))
        assert result.status_code == 200
        assert result.json() == DEFAULTS
        assert writes == []
    finally:
        event.remove(client.app.state.engine, 'before_cursor_execute', track)
    assert client.get('/v1/settings').status_code == 401


def test_settings_crud_and_reset_prevent_stale_recreation(clients):
    client, _ = clients
    vehicle = create_vehicle(client)
    saved = client.put('/v1/settings', headers=h('alice'), json=preferences(vehicle=vehicle))
    assert saved.status_code == 200, saved.text
    expected = {'revision': 1, 'customized': True, 'default_vehicle_id': vehicle,
                'default_estimate_discipline': 'collision', 'home_tab': 'estimates'}
    assert saved.json() == expected
    assert client.get('/v1/settings', headers=h('alice')).json() == expected
    assert client.get('/v1/bootstrap', headers=h('alice')).json()['settings'] == expected
    assert client.get('/v1/settings', headers=h('bob')).json() == DEFAULTS
    stale = client.put('/v1/settings', headers=h('alice'), json=preferences())
    assert stale.status_code == 409 and stale.json()['code'] == 'settings_conflict'
    assert client.delete('/v1/settings?expected_revision=0', headers=h('alice')).status_code == 409
    cleared = client.delete('/v1/settings?expected_revision=1', headers=h('alice'))
    assert cleared.status_code == 200 and cleared.json() == {**DEFAULTS, 'revision': 2}
    assert client.put('/v1/settings', headers=h('alice'), json=preferences()).status_code == 409
    recreated = client.put('/v1/settings', headers=h('alice'), json=preferences(2))
    assert recreated.status_code == 200 and recreated.json()['revision'] == 3
    # Reset changes no related data or account identity.
    bootstrap = client.get('/v1/bootstrap', headers=h('alice')).json()
    assert bootstrap['profile']['email'] == 'alice@example.test'
    assert bootstrap['vehicles'][0]['id'] == vehicle


@pytest.mark.parametrize('changes', [
    {'expected_revision': True}, {'expected_revision': 0.0}, {'expected_revision': '0'},
    {'expected_revision': -1}, {'default_vehicle_id': ''}, {'default_vehicle_id': 1},
    {'default_estimate_discipline': 'repair'}, {'home_tab': 'admin'},
    {'customer_id': 'bob-id'}, {'customized': True},
])
def test_settings_reject_invalid_and_identity_fields(clients, changes):
    client, _ = clients
    response = client.put('/v1/settings', headers=h('alice'), json=preferences(**changes))
    assert response.status_code == 422, response.text


def test_settings_require_full_body_and_reset_revision(clients):
    client, _ = clients
    assert client.put('/v1/settings', headers=h('alice'), json={'expected_revision': 0}).status_code == 422
    for query in ('', '?expected_revision=-1', '?expected_revision=true', '?expected_revision=1.5'):
        assert client.delete('/v1/settings' + query, headers=h('alice')).status_code == 422


def test_settings_vehicle_ownership_and_deletion_revision(clients):
    client, _ = clients
    vehicle = create_vehicle(client)
    other = create_vehicle(client, 'bob')
    for invalid in (other, 'missing'):
        assert client.put('/v1/settings', headers=h('alice'), json=preferences(vehicle=invalid)).status_code == 404
    assert client.put('/v1/settings', headers=h('alice'), json=preferences(vehicle=vehicle)).status_code == 200
    assert client.delete(f'/v1/vehicles/{vehicle}', headers=h('bob')).status_code == 404
    assert client.delete(f'/v1/vehicles/{vehicle}', headers=h('alice')).status_code == 204
    result = client.get('/v1/settings', headers=h('alice')).json()
    assert result == {'revision': 2, 'customized': True, 'default_vehicle_id': None,
                      'default_estimate_discipline': 'collision', 'home_tab': 'estimates'}
    assert client.put('/v1/settings', headers=h('alice'), json=preferences(1)).status_code == 409


def test_concurrent_settings_writes_only_one_editor_wins(clients):
    client, _ = clients
    client.get('/v1/bootstrap', headers=h('alice'))
    with ThreadPoolExecutor(max_workers=6) as pool:
        responses = list(pool.map(lambda _: client.put('/v1/settings', headers=h('alice'), json=preferences()), range(6)))
    assert sorted(r.status_code for r in responses) == [200, 409, 409, 409, 409, 409]
    assert client.get('/v1/settings', headers=h('alice')).json()['revision'] == 1


def test_profile_partial_update_reset_and_revision_preserve_identity(clients):
    client, _ = clients
    vehicle = create_vehicle(client)
    profile = client.get('/v1/profile', headers=h('alice'))
    assert profile.status_code == 200
    assert profile.json()['revision'] == 1
    saved = client.put('/v1/profile', headers=h('alice'), json={
        'expected_revision': 1, 'name': '  Alice Driver  ', 'phone': '  +1 (303) 555-0100  ',
        'postal_code': '80202-1234', 'contact_preference': 'phone'})
    assert saved.status_code == 200, saved.text
    assert saved.json()['name'] == 'Alice Driver' and saved.json()['phone'] == '+1 (303) 555-0100'
    partial = client.put('/v1/profile', headers=h('alice'), json={'expected_revision': 2, 'postal_code': ''})
    assert partial.status_code == 200 and partial.json()['revision'] == 3
    assert partial.json()['phone'] == '+1 (303) 555-0100' and partial.json()['name'] == 'Alice Driver'
    stale = client.put('/v1/profile', headers=h('alice'), json={'expected_revision': 2, 'name': 'Stale'})
    assert stale.status_code == 409 and stale.json()['code'] == 'profile_conflict'
    assert client.delete('/v1/profile?expected_revision=2', headers=h('alice')).status_code == 409
    reset = client.delete('/v1/profile?expected_revision=3', headers=h('alice'))
    assert reset.status_code == 200
    assert reset.json() == {'id': 'alice-id', 'email': 'alice@example.test', 'name': '', 'phone': '',
                            'postal_code': '', 'contact_preference': 'email', 'revision': 4}
    assert client.get('/v1/bootstrap', headers=h('alice')).json()['vehicles'][0]['id'] == vehicle
    assert client.get('/v1/profile', headers=h('bob')).json()['revision'] == 0
    # Old clients without a revision continue to update only supplied fields.
    assert client.put('/v1/profile', headers=h('alice'), json={'name': 'Restored'}).json()['revision'] == 5


@pytest.mark.parametrize('body', [
    {'phone': 'not a phone'}, {'phone': '123'}, {'phone': '1' * 16}, {'phone': '3035550100 ext 2'},
    {'phone': '3035550100\n'}, {'phone': '＋١٢٣٤٥٦٧٨٩'}, {'name': 'A\x00B'},
    {'contact_preference': 'phone'}, {'name': None}, {'postal_code': None},
    {'contact_preference': None}, {'expected_revision': None}, {'expected_revision': True},
    {'expected_revision': 1.0}, {'id': 'bob-id'}, {'email': 'attacker@test'}, {'demo': True},
])
def test_profile_rejects_invalid_fields_without_mutation(clients, body):
    client, _ = clients
    result = client.put('/v1/profile', headers=h('alice'), json=body)
    assert result.status_code == 422, result.text
    assert client.get('/v1/profile', headers=h('alice')).json()['revision'] == 0


def test_profile_phone_preference_is_validated_against_merged_fields(clients):
    client, _ = clients
    assert client.put('/v1/profile', headers=h('alice'), json={'phone': '303.555.0100'}).status_code == 200
    assert client.put('/v1/profile', headers=h('alice'), json={'contact_preference': 'phone'}).status_code == 200
    assert client.put('/v1/profile', headers=h('alice'), json={'phone': ''}).status_code == 422
    cleared = client.put('/v1/profile', headers=h('alice'), json={'phone': '', 'contact_preference': 'email'})
    assert cleared.status_code == 200 and cleared.json()['phone'] == ''
    assert client.delete('/v1/profile', headers=h('alice')).status_code == 422


def test_concurrent_profile_edits_only_one_revision_wins(clients):
    client, _ = clients
    client.get('/v1/bootstrap', headers=h('alice'))
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda i: client.put('/v1/profile', headers=h('alice'),
            json={'name': f'Editor {i}', 'expected_revision': 0}), range(4)))
    assert sorted(r.status_code for r in responses) == [200, 409, 409, 409]
    assert client.get('/v1/profile', headers=h('alice')).json()['revision'] == 1


def test_knowledge_preferences_read_and_audited_optout(clients):
    from estimoto_plus.graph_models import KnowledgeConsentEvent
    client, _ = clients
    response = client.get('/v1/knowledge/preferences', headers=h('alice'))
    assert response.status_code == 200 and response.json()['share_aggregate_insights'] is False
    policy = response.json()['policy_version']
    for value in (True, False):
        changed = client.put('/v1/knowledge/preferences', headers=h('alice'), json={'share_aggregate_insights': value})
        assert changed.status_code == 200
        assert client.get('/v1/knowledge/preferences', headers=h('alice')).json() == {
            'share_aggregate_insights': value, 'policy_version': policy}
    assert client.get('/v1/knowledge/preferences', headers=h('bob')).json()['share_aggregate_insights'] is False
    with client.app.state.session_factory() as db:
        assert db.query(KnowledgeConsentEvent).filter_by(customer_id='alice-id').count() == 2


def test_settings_migration_backfills_profile_and_persists_after_restart(tmp_path, monkeypatch):
    path = tmp_path / 'migration.sqlite'
    url = f'sqlite:///{path}'
    monkeypatch.setenv('DATABASE_URL', url)
    root = Path(__file__).resolve().parents[1]
    config = Config(str(root / 'alembic.ini'))
    config.set_main_option('script_location', str(root / 'alembic'))
    command.upgrade(config, 'd9e4b82013c7')
    with sqlite3.connect(path) as db:
        db.execute("INSERT INTO customers (id,email,name,phone,postal_code,contact_preference,demo) VALUES ('alice-id','alice@example.test','Alice','','80202','email',0)")
    command.upgrade(config, 'head')
    settings = Settings(database_url=url, environment='development', photo_dir=str(tmp_path / 'photos'), worker_enabled=False)
    verify = lambda _: {'id': 'alice-id', 'email': 'alice@example.test', 'email_confirmed_at': 'yes'}
    app = create_app(settings, auth_verifier=verify)
    with TestClient(app) as client:
        profile = client.get('/v1/profile', headers=h('alice'))
        assert profile.status_code == 200 and profile.json()['name'] == 'Alice' and profile.json()['revision'] == 0
        assert client.put('/v1/settings', headers=h('alice'), json=preferences()).status_code == 200
    app.state.engine.dispose()
    second = create_app(settings, auth_verifier=verify)
    with TestClient(second) as client:
        result = client.get('/v1/settings', headers=h('alice')).json()
        assert result['revision'] == 1 and result['home_tab'] == 'estimates'
    second.state.engine.dispose()
    command.downgrade(config, 'd9e4b82013c7')
    with sqlite3.connect(path) as db:
        assert 'profile_revision' not in {row[1] for row in db.execute('PRAGMA table_info(customers)')}
        assert db.execute("SELECT name FROM customers WHERE id='alice-id'").fetchone() == ('Alice',)
        assert db.execute("SELECT name FROM sqlite_master WHERE name='customer_settings'").fetchone() is None
    command.upgrade(config, 'head')
