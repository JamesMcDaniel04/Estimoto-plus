#!/usr/bin/env python3
"""Boot an isolated migrated API and fictional local identity/bridge fixtures.

Run with backend/.venv/bin/python scripts/smoke_api.py [--flutter-client].
No production configuration is inherited and no external service is contacted.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time

import httpx
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise AssertionError(message)


@contextmanager
def fixtures():
    tokens = {secrets.token_urlsafe(24): name for name in ('socket-a', 'socket-b')}
    bridge_key = secrets.token_urlsafe(32)
    deliveries = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            name = tokens.get(self.headers.get('Authorization', '').removeprefix('Bearer '))
            if self.path != '/auth/v1/user' or name is None:
                return self.reply(401, {})
            self.reply(200, {'id': name, 'email': f'{name}@example.test', 'email_confirmed_at': '2026-09-13T00:00:00Z'})

        def do_POST(self):
            if self.path != '/receive' or self.headers.get('X-Bridge-Key') != bridge_key:
                return self.reply(401, {})
            size = int(self.headers.get('Content-Length', '0'))
            if size > 1_000_000:
                return self.reply(413, {})
            body = json.loads(self.rfile.read(size))
            key = self.headers.get('Idempotency-Key')
            if not any(item[0] == key for item in deliveries):
                deliveries.append((key, body))
            self.reply(200, {'receipt_id': f'receipt-{key}'})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', list(tokens), bridge_key, deliveries
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@contextmanager
def api_process(env, port, log_path):
    with log_path.open('a') as log:
        process = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'estimoto_plus.app:create_app', '--factory', '--host', '127.0.0.1', '--port', str(port)], cwd=ROOT / 'backend', env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            with httpx.Client(timeout=1, trust_env=False) as client:
                while time.monotonic() < deadline:
                    check(process.poll() is None, 'API process exited during startup.')
                    try:
                        if client.get(f'http://127.0.0.1:{port}/v1/bootstrap').status_code == 401:
                            break
                    except httpx.HTTPError:
                        pass
                    time.sleep(0.1)
                else:
                    raise AssertionError('API startup timed out.')
            yield f'http://127.0.0.1:{port}'
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def run(flutter_client):
    with tempfile.TemporaryDirectory(prefix='estimoto-plus-smoke-') as directory, fixtures() as (fixture_url, tokens, bridge_key, deliveries):
        temp = Path(directory)
        # Retain only process/runtime settings; provider credentials and toggles
        # from the caller must never activate a live integration in this smoke.
        env = {key: value for key, value in os.environ.items()
               if key in {'PATH', 'HOME', 'LANG', 'LC_ALL', 'SYSTEMROOT', 'TMPDIR'}}
        env.update({'DATABASE_URL': f'sqlite:///{temp / "customer.sqlite"}', 'ENVIRONMENT': 'development', 'PHOTO_DIR': str(temp / 'photos'), 'SUPABASE_URL': fixture_url, 'SUPABASE_PUBLISHABLE_KEY': 'fictional-local-publishable-key', 'BRIDGE_REQUEST_URL': fixture_url + '/receive', 'BRIDGE_ESTIMATE_URL': '', 'BRIDGE_KEY': bridge_key, 'DEV_SESSIONS_ENABLED': 'true', 'DEV_TOKEN_SECRET': secrets.token_urlsafe(40), 'CORS_ORIGINS': 'http://127.0.0.1:4318', 'PYTHONPATH': str(ROOT / 'backend'), 'WORKER_ENABLED': 'false', 'PLACES_ENABLED': 'false', 'DISCOVERY_ENABLED': 'false', 'GOOGLE_CALENDAR_ENABLED': 'false', 'VALUATION_ENABLED': 'false', 'HTTP_PROXY': '', 'HTTPS_PROXY': '', 'ALL_PROXY': '', 'NO_PROXY': '127.0.0.1,localhost'})
        subprocess.run([sys.executable, '-m', 'alembic', 'upgrade', 'head'], cwd=ROOT / 'backend', env=env, check=True)
        subprocess.run([sys.executable, '-m', 'alembic', 'check'], cwd=ROOT / 'backend', env=env, check=True)
        port = free_port()
        auth = {'Authorization': 'Bearer ' + tokens[0]}
        bridge = {'X-Bridge-Key': bridge_key}
        with api_process(env, port, temp / 'api.log') as url, httpx.Client(base_url=url, headers=auth, timeout=10, trust_env=False) as client:
            check(client.get('/v1/bootstrap').status_code == 200, 'Identity fixture failed.')
            profile = client.get('/v1/profile').json()
            saved_profile = client.put('/v1/profile', json={'name': 'Socket Customer', 'phone': '+1 (303) 555-0100', 'postal_code': '80202-1234', 'expected_revision': profile['revision']}).json()
            check(saved_profile['revision'] == 1 and saved_profile['postal_code'] == '80202', 'Profile save or ZIP canonicalization failed.')
            partial_profile = client.put('/v1/profile', json={'name': 'Socket Driver', 'expected_revision': 1}).json()
            check(partial_profile['revision'] == 2 and partial_profile['postal_code'] == '80202' and partial_profile['phone'] == saved_profile['phone'], 'Partial profile save erased omitted details.')
            car = client.post('/v1/vehicles', json={'year': 2024, 'make': 'Toyota', 'model': 'Camry', 'mileage': 8200}).json()
            provider = client.post('/v1/bridge/providers', headers=bridge, json={'source_id': 'socket-provider', 'name': 'Fictional Socket Dent Care', 'kind': 'technician', 'specialties': ['pdr'], 'postal_codes': ['80202'], 'public_visible': True, 'accepting_requests': True, 'mobile_service': True}).json()
            body = {'vehicle_id': car['id'], 'provider_id': provider['id'], 'specialty': 'pdr', 'description': 'Socket door dent.', 'preferred_time': 'Next week', 'share_contact': True}
            request = client.post('/v1/requests', json=body, headers={'Idempotency-Key': 'socket-request'}).json()
            replay = client.post('/v1/requests', json=body, headers={'Idempotency-Key': 'socket-request'}).json()
            check(replay['id'] == request['id'] and request['status'] == 'requested', 'Idempotent pending request failed.')
            check(client.post('/v1/bridge/outbox/deliver', headers=bridge).status_code == 200, 'Bridge delivery failed.')
            check(len(deliveries) == 1 and deliveries[0][1]['event'] == 'created', 'Fictional receiver did not persist creation.')
            state = client.get('/v1/bootstrap').json()
            check(state['requests'][0]['delivery_status'] == 'delivered' and state['requests'][0]['status'] == 'requested', 'Delivery incorrectly accepted or booked request.')
            check(client.post(f'/v1/requests/{request["id"]}/cancel').status_code == 200, 'Cancellation failed.')
            check(client.post('/v1/bridge/outbox/deliver', headers=bridge).status_code == 200, 'Cancellation delivery failed.')
            check(any(data['event'] == 'cancelled' for _, data in deliveries), 'Cancellation did not reach fictional receiver.')
            draft = client.post('/v1/estimates', json={'vehicle_id': car['id'], 'discipline': 'pdr', 'description': 'Door dent', 'date_of_loss': None}).json()
            data = BytesIO()
            Image.new('RGB', (8, 8), (20, 90, 170)).save(data, format='JPEG')
            photo = client.post(f'/v1/estimates/{draft["id"]}/photos', data={'label': 'Damage detail'}, files={'file': ('test.jpg', data.getvalue(), 'image/jpeg')}).json()
            photo_url = f'/v1/estimates/{draft["id"]}/photos/{photo["id"]}'
            image = client.get(photo_url)
            check(image.status_code == 200 and image.headers['content-type'].startswith('image/'), 'Private photo could not be read back.')
            reminder = client.post('/v1/reminders', json={'vehicle_id': car['id'], 'title': 'Socket reminder', 'due_mileage': 9000}).json()
            check(client.put(f'/v1/reminders/{reminder["id"]}', json={'title': 'Socket reminder edited'}).json()['title'] == 'Socket reminder edited', 'Reminder edit failed.')
            check(client.post(f'/v1/reminders/{reminder["id"]}/complete').json()['completed'] and not client.post(f'/v1/reminders/{reminder["id"]}/reopen').json()['completed'], 'Reminder reopen failed.')
            check(client.delete(f'/v1/reminders/{reminder["id"]}').status_code == 204, 'Reminder delete failed.')
            scratch = client.post('/v1/estimates', json={'vehicle_id': car['id'], 'discipline': 'pdr', 'description': 'Scratch draft', 'date_of_loss': None}).json()
            check(client.put(f'/v1/estimates/{scratch["id"]}', json={'description': 'Scratch draft edited'}).json()['description'] == 'Scratch draft edited', 'Estimate edit failed.')
            scratch_photo = client.post(f'/v1/estimates/{scratch["id"]}/photos', data={'label': 'Scratch'}, files={'file': ('scratch.jpg', data.getvalue(), 'image/jpeg')}).json()
            check(client.delete(f'/v1/estimates/{scratch["id"]}/photos/{scratch_photo["id"]}').status_code == 204, 'Estimate photo delete failed.')
            check(client.delete(f'/v1/estimates/{scratch["id"]}').status_code == 204, 'Estimate delete failed.')
            check(all(e['id'] != scratch['id'] for e in client.get('/v1/bootstrap').json()['estimates']), 'Deleted estimate still listed.')
            other = {'Authorization': 'Bearer ' + tokens[1]}
            check(client.get(photo_url, headers=other).status_code == 404, 'Cross-customer photo access allowed.')
            check(client.put(f'/v1/vehicles/{car["id"]}', headers=other, json={'mileage': 1}).status_code == 404, 'Cross-customer garage edit allowed.')
            check(client.get('/v1/bootstrap', headers=other).json()['requests'] == [], 'Cross-customer request leaked.')
            defaults = client.get('/v1/settings').json()
            check(defaults == {'revision': 0, 'customized': False, 'default_vehicle_id': None, 'default_estimate_discipline': 'pdr', 'home_tab': 'garage'}, 'Unset app preferences did not return defaults.')
            preferences = {'expected_revision': 0, 'default_vehicle_id': car['id'], 'default_estimate_discipline': 'collision', 'home_tab': 'find_help'}
            saved_settings = client.put('/v1/settings', json=preferences).json()
            check(saved_settings['revision'] == 1 and saved_settings['customized'] and saved_settings['default_vehicle_id'] == car['id'], 'App preferences save failed.')
            conflict = client.put('/v1/settings', json={**preferences, 'home_tab': 'repairs'})
            check(conflict.status_code == 409 and conflict.json()['code'] == 'settings_conflict', 'Stale app preferences overwrote saved values.')
            reset_settings = client.delete('/v1/settings', params={'expected_revision': 1}).json()
            check(reset_settings == {**defaults, 'revision': 2}, 'Preferences reset lost its revision tombstone.')
            stale_reset = client.delete('/v1/settings', params={'expected_revision': 1})
            check(stale_reset.status_code == 409, 'Stale preferences reset was accepted.')
            saved_settings = client.put('/v1/settings', json={**preferences, 'expected_revision': 2}).json()
            check(saved_settings['revision'] == 3, 'Preferences could not be recreated after reset.')
            check(client.get('/v1/settings', headers=other).json() == defaults, 'App preferences leaked across customers.')
            check(client.put('/v1/settings', headers=other, json=preferences).status_code == 404, 'A customer selected another customer vehicle as default.')
            privacy = client.get('/v1/knowledge/preferences').json()
            check(privacy['share_aggregate_insights'] is False, 'Aggregate sharing was enabled by default.')
            saved_privacy = client.put('/v1/knowledge/preferences', json={'share_aggregate_insights': True}).json()
            check(saved_privacy['share_aggregate_insights'] and saved_privacy['policy_version'] == privacy['policy_version'], 'Privacy preferences save failed.')
            check(client.get('/v1/knowledge').json()['preferences']['share_aggregate_insights'], 'Settings privacy and service-history privacy diverged.')
            check(not client.get('/v1/knowledge/preferences', headers=other).json()['share_aggregate_insights'], 'Privacy preferences leaked across customers.')
            cleared_profile = client.delete('/v1/profile', params={'expected_revision': 2}).json()
            check(cleared_profile == {**profile, 'revision': 3}, 'Clearing contact details changed account identity or retained contact data.')
            stale_profile = client.put('/v1/profile', json={'expected_revision': 2, 'name': 'Stale name'})
            check(stale_profile.status_code == 409 and stale_profile.json()['code'] == 'profile_conflict', 'A stale editor restored cleared profile details.')
            check(client.put('/v1/profile', json={'id': 'other-customer'}).status_code == 422, 'Profile settings allowed account identity mutation.')
            check(client.get('/v1/bootstrap').json()['settings'] == saved_settings, 'Bootstrap omitted saved preferences.')
            if flutter_client:
                subprocess.run(['dart', 'run', 'tool/smoke_api.dart'], cwd=ROOT / 'app', env={**env, 'PLUS_SMOKE_API': url}, check=True)
        with api_process(env, port, temp / 'api.log') as url, httpx.Client(base_url=url, headers=auth, timeout=10, trust_env=False) as client:
            state = client.get('/v1/bootstrap').json()
            check(any(v['id'] == car['id'] for v in state['vehicles']), 'Restart lost garage records.')
            check(state['requests'][0]['status'] == 'cancelled', 'Restart lost request cancellation.')
            check(client.get(photo_url).status_code == 200, 'Restart lost private photo.')
            check(state['profile'] == cleared_profile, 'Restart restored cleared profile details or changed account identity.')
            check(state['settings'] == saved_settings, 'Restart lost app preferences or their revision.')
            check(client.get('/v1/knowledge/preferences').json() == saved_privacy, 'Restart lost privacy consent.')
            final_settings = client.delete('/v1/settings', params={'expected_revision': saved_settings['revision']}).json()
            check(final_settings == {**defaults, 'revision': 4}, 'Persisted preferences could not be reset after restart.')
            check(client.put('/v1/knowledge/preferences', json={'share_aggregate_insights': False}).status_code == 200, 'Aggregate sharing could not be disabled.')
        with api_process(env, port, temp / 'api.log') as url, httpx.Client(base_url=url, headers=auth, timeout=10, trust_env=False) as client:
            check(client.get('/v1/settings').json() == final_settings, 'Restart lost the preferences reset revision.')
            check(not client.get('/v1/knowledge/preferences').json()['share_aggregate_insights'], 'Restart restored withdrawn privacy consent.')
            conflict = client.put('/v1/settings', json={**preferences, 'expected_revision': 3})
            check(conflict.status_code == 409 and conflict.json()['code'] == 'settings_conflict', 'A stale editor recreated reset preferences after restart.')
        print('API socket smoke: migrations, isolated identities, settings/profile/privacy CRUD and conflicts, private photos, reminder and draft edit/delete, durable request/replay/cancel, fictional bridge receipts and restart persistence passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-client', action='store_true')
    run(parser.parse_args().flutter_client)
