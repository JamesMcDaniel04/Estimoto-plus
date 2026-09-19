from fastapi.testclient import TestClient
import pytest

from estimoto_plus.app import create_app
from estimoto_plus.config import Settings


@pytest.fixture
def production(tmp_path, monkeypatch):
    monkeypatch.setattr('os.path.ismount', lambda _: True)
    web = tmp_path / 'web'
    web.mkdir()
    for name in ('index.html', 'flutter_bootstrap.js', 'main.dart.js', 'flutter_service_worker.js'):
        (web / name).write_text('fixture')
    (web / 'capture').mkdir()
    (web / 'capture' / 'index.html').write_text('capture fixture')
    settings = Settings(environment='production', worker_enabled=False,
        database_url='postgresql+psycopg://fixture@127.0.0.1/unused_test',
        photo_dir=str(tmp_path / 'photos'), web_dir=str(web),
        supabase_url='https://auth.example', supabase_publishable_key='public-fixture',
        bridge_url='https://bridge.example/requests', estimate_bridge_url='https://bridge.example/estimates',
        bridge_key='fixture-only', source_sha='surface-test')
    app = create_app(settings)
    with TestClient(app) as client:
        yield client
    app.state.engine.dispose()


def test_production_has_no_interactive_or_machine_readable_docs(production):
    for path in ('/docs', '/redoc', '/openapi.json'):
        assert production.get(path).status_code == 404
    assert production.get('/health/live').status_code == 200


def test_shell_revalidates_and_cannot_be_framed_but_guided_capture_remains_embeddable(production):
    for path in ('/', '/index.html', '/flutter_bootstrap.js', '/main.dart.js', '/flutter_service_worker.js'):
        response = production.get(path)
        assert response.status_code == 200
        assert response.headers['cache-control'] == 'no-cache, max-age=0, must-revalidate'
        assert "frame-ancestors 'none'" in response.headers['content-security-policy']
        assert response.headers['x-frame-options'] == 'DENY'
        assert response.headers['strict-transport-security'] == 'max-age=31536000; includeSubDomains'
    capture = production.get('/capture/index.html')
    assert capture.status_code == 200
    assert "frame-ancestors 'self'" in capture.headers['content-security-policy']
    assert capture.headers['x-frame-options'] == 'SAMEORIGIN'


def test_api_auth_errors_keep_private_no_store(production):
    response = production.get('/v1/bootstrap')
    assert response.status_code == 401
    assert response.headers['cache-control'] == 'private, no-store'


def test_development_docs_remain_available(tmp_path):
    app = create_app(Settings(environment='test', database_url='sqlite://',
                              photo_dir=str(tmp_path), worker_enabled=False))
    with TestClient(app) as client:
        assert client.get('/docs').status_code == 200
        assert client.get('/openapi.json').status_code == 200
        assert 'strict-transport-security' not in client.get('/health/live').headers
    app.state.engine.dispose()


def test_unexpected_errors_are_json_without_traces_and_stay_private(tmp_path):
    app = create_app(Settings(environment='test', database_url='sqlite://',
                              photo_dir=str(tmp_path), worker_enabled=False))

    @app.get('/boom')
    def boom():
        raise RuntimeError('secret detail')

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get('/boom')
    assert response.status_code == 500
    assert response.json() == {'detail': 'Something went wrong. Please try again.'}
    assert 'secret' not in response.text
    assert response.headers['cache-control'] == 'private, no-store'
    assert response.headers['x-content-type-options'] == 'nosniff'
