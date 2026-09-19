import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from uuid import uuid4

import httpx
import pytest

from test_api import clients as api_clients, create_vehicle, h


@pytest.fixture
def clients(tmp_path, monkeypatch):
    supplied = os.getenv('DISCOVERY_TEST_POSTGRES_URL')
    if not supplied:
        for value in api_clients.__wrapped__(tmp_path):
            install_review_fixtures(value[0], monkeypatch)
            yield value
        return
    from sqlalchemy import create_engine, text
    from sqlalchemy.engine import make_url
    from fastapi.testclient import TestClient
    from estimoto_plus.app import create_app
    from estimoto_plus.config import Settings
    url = make_url(supplied)
    assert url.host in ('127.0.0.1', 'localhost') and 'test' in url.database
    schema = 'discovery_test_' + uuid4().hex
    admin = create_engine(url)
    with admin.begin() as db:
        db.execute(text(f'CREATE SCHEMA "{schema}"'))
    database_url = url.update_query_dict({'options': f'-csearch_path={schema}'}).render_as_string(hide_password=False)
    settings = Settings(database_url=database_url, environment='test', worker_enabled=False, photo_dir=str(tmp_path / 'photos'),
                        bridge_key='bridge-secret', bridge_url='https://bridge.example/requests')
    sent = []
    app = create_app(settings, auth_verifier=lambda token: {'id': token + '-id', 'email': token + '@example.test', 'confirmed_at': 'ok'},
                     bridge_transport=httpx.MockTransport(lambda r: (sent.append(r), httpx.Response(202, json={'receipt_id': 'upstream-1'}))[1]))
    try:
        with TestClient(app) as client:
            install_review_fixtures(client, monkeypatch)
            yield client, sent
    finally:
        app.state.engine.dispose()
        with admin.begin() as db:
            db.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin.dispose()


def install_review_fixtures(client, monkeypatch):
    """Directory transport fixtures represent explicitly reviewed businesses.

    Exercise the real identity/expiry/contact enrichment path, with no network
    business research in unit tests. Negative tests remove approval explicitly.
    """
    from estimoto_plus import reviewed_shops, official_shops
    monkeypatch.setattr(official_shops, 'catalog', lambda: {})
    from estimoto_plus.discovery_provider import normalize_listing
    from estimoto_plus.models import now
    def approved():
        stub = getattr(client.app.state, 'reviewed_business_fixtures', None)
        entries = {}
        for element in stub.elements if stub else []:
            row = normalize_listing(element)
            if row is None or element['id'] in stub.unreviewed_ids:
                continue
            entries[row['source_id']] = {
                'source_id': row['source_id'], 'name': row['name'], 'address': row['address'],
                'source_point': row['point'], 'business_verified': True,
                'verified_address': row['address'] or '1 Fixture Street Denver CO 80204',
                'website': 'https://fixture.example/', 'phone': row['phone'],
                'verification_url': 'https://fixture.example/contact', 'checked_at': now().date().isoformat(),
                'description': 'Fixture repair services', 'specialties': row['specialties'],
                'evidence': 'Synthetic business verification fixture.',
            }
        return entries
    monkeypatch.setattr(reviewed_shops, 'catalog', approved)


class DirectoryStub:
    def __init__(self):
        self.calls = []
        self.fail = False
        self.unreviewed_ids = set()
        self.elements = [self.shop(1, 'General repair'), self.shop(2, 'Audi specialist', {'service:vehicle:brand': 'Audi'})]

    @staticmethod
    def shop(identifier, name, tags=None, lat=39.75, lon=-105.02):
        return {'type': 'node', 'id': identifier, 'lat': lat, 'lon': lon,
                'tags': {'shop': 'car_repair', 'name': name, 'phone': '+1 303 555 0100', **(tags or {})}}

    def __call__(self, request):
        self.calls.append(request)
        if self.fail:
            return httpx.Response(503)
        if request.url.host == 'api.zippopotam.us':
            postal = request.url.path.split('/')[-1]
            lat = '39.82' if postal == '80221' else '39.734'
            return httpx.Response(200, json={'post code': postal, 'country abbreviation': 'US',
                'places': [{'latitude': lat, 'longitude': '-105.0259', 'place name': 'Denver', 'state abbreviation': 'CO'}]})
        assert request.url.host in ('overpass-api.de', 'overpass.private.coffee')
        assert request.method == 'POST'
        return httpx.Response(200, json={'elements': self.elements})


def setup(client):
    vehicle = create_vehicle(client)
    assert client.put('/v1/profile', headers=h('alice'), json={'name': 'Alice', 'phone': '3035550123', 'postal_code': '80204'}).status_code == 200
    client.app.state.settings.discovery_enabled = True
    stub = DirectoryStub()
    client.app.state.reviewed_business_fixtures = stub
    client.app.state.discovery_transport = httpx.MockTransport(stub)
    return vehicle, stub


def partner(client):
    return client.post('/v1/bridge/providers', headers={'X-Bridge-Key': 'bridge-secret'}, json={
        'source_id': 'demolition-fixture', 'name': 'Demolition Dent fixture', 'kind': 'shop',
        'specialties': ['pdr', 'collision'], 'postal_codes': ['80221'], 'address': '1 Example St, Denver CO 80221',
        'city': 'Denver', 'phone': '3035550100', 'public_visible': True, 'accepting_requests': True}).json()['id']


def test_nearby_partner_is_shop_visit_mobile_fallback_and_assistant_matches(clients):
    client, _ = clients
    vehicle, stub = setup(client)
    provider = partner(client)
    response = client.get('/v1/discovery', headers=h('alice'), params={
        'postal_code': '80204', 'vehicle_id': vehicle, 'specialty': 'pdr', 'mobile_only': True})
    assert response.status_code == 200
    data = response.json()
    assert data['providers'] == []
    assert data['shop_visit_alternatives'][0]['id'] == provider
    assert data['shop_visit_alternatives'][0]['request_modes'] == ['shop_visit']
    assert data['exhaustive'] is False and data['distance_basis'] == 'zip_centroid'
    answer = client.post('/v1/assistant', headers=h('alice'), json={'message': 'Find mobile dent repair', 'vehicle_id': vehicle}).json()
    assert provider in [p['id'] for p in answer['providers']]
    assert 'visit' in answer['reply'].lower() and 'Demolition' in answer['reply']


def test_public_filters_cap_provenance_and_vehicle_ownership(clients):
    client, _ = clients
    vehicle, stub = setup(client)
    for index, tags in enumerate([{'access': 'private'}, {'access': 'no'}, {'fleet': 'yes'}, {'disused': 'yes'}, {'name': ''}], 900):
        stub.elements.append(stub.shop(index, 'Do not list', tags))
    stub.elements.extend(stub.shop(i, f'Public {i}') for i in range(3, 120))
    stub.elements.append(stub.shop(1000, 'Outside', lat=41))
    stub.elements.append(stub.shop(1001, 'Audi chain brand', {'brand': 'Audi'}))
    client.put('/v1/vehicles/' + vehicle, headers=h('alice'), json={'make': 'Audi'})
    data = client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': vehicle}).json()
    assert len(data['providers']) == 30 and data['truncated'] is True
    assert not any(p['name'] in ('Do not list', 'Outside') for p in data['providers'])
    assert data['providers'][0]['name'] == 'Audi specialist'
    assert all(p['accepting_requests'] is False and p['request_modes'] == [] for p in data['providers'])
    assert client.get('/v1/discovery', headers=h('bob'), params={'vehicle_id': vehicle, 'postal_code': '80204'}).status_code == 404
    assert client.get('/v1/discovery', params={'postal_code': '80204'}).status_code == 401


def test_public_cache_shared_and_stale_is_explicit(clients):
    from estimoto_plus.discovery_models import DirectoryCache
    from estimoto_plus.models import now
    client, _ = clients
    _, stub = setup(client)
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda _: client.get('/v1/discovery', headers=h('alice')), range(4)))
    assert any(r.json()['status'] == 'ready' for r in responses)
    assert len([r for r in stub.calls if r.url.host == 'overpass-api.de']) == 1
    with client.app.state.session_factory() as db:
        for row in db.query(DirectoryCache).filter(DirectoryCache.fetched_at.is_not(None)).all():
            row.fetched_at = now() - timedelta(days=2)
        db.commit()
    stub.fail = True
    data = client.get('/v1/discovery', headers=h('alice')).json()
    assert data['status'] == 'stale' and data['providers']


def test_overlong_vehicle_id_is_rejected_before_any_lookup(clients, monkeypatch):
    from estimoto_plus import discovery, customer_routes
    client, _ = clients
    create_vehicle(client)

    def never(*_args, **_kwargs):
        raise AssertionError('vehicle lookup must not run for an over-long vehicle_id')
    monkeypatch.setattr(discovery, 'owned_vehicle', never)
    monkeypatch.setattr(customer_routes, 'owned', never)
    too_long = 'v' * 37
    assert client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': too_long}).status_code == 422
    assert client.get('/v1/discovery/favorites', headers=h('alice'), params={'vehicle_id': too_long}).status_code == 422
    assert client.delete('/v1/discovery/favorites/pdr', headers=h('alice'), params={'vehicle_id': too_long}).status_code == 422
    assert client.post('/v1/assistant', headers=h('alice'), json={'message': 'hello', 'vehicle_id': too_long}).status_code == 422


def test_favorites_private_idempotent_and_source_validated(clients):
    client, _ = clients
    vehicle, _ = setup(client)
    data = client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': vehicle}).json()
    listing = data['providers'][0]
    body = {'vehicle_id': vehicle, 'source': listing['source'], 'source_id': listing['source_id']}
    path = '/v1/discovery/favorites/mechanical'
    first = client.put(path, headers=h('alice'), json=body)
    assert first.status_code == 200
    assert client.put(path, headers=h('alice'), json=body).json() == first.json()
    assert client.put(path, headers=h('bob'), json=body).status_code == 404
    assert client.put(path, headers=h('alice'), json={**body, 'source_id': 'node:99999999'}).status_code == 422
    assert len(client.get('/v1/discovery/favorites', headers=h('alice'), params={'vehicle_id': vehicle}).json()) == 1
    assert client.delete(path, headers=h('alice'), params={'vehicle_id': vehicle}).status_code == 200


def test_explicit_shop_visit_is_admitted_without_changing_legacy_zip_rules(clients):
    from estimoto_plus.models import Outbox
    client, _ = clients
    vehicle, _ = setup(client)
    provider = partner(client)
    body = {'vehicle_id': vehicle, 'provider_id': provider, 'specialty': 'pdr', 'description': 'Dent repair', 'share_contact': True}
    assert client.post('/v1/requests', headers={**h('alice'), 'Idempotency-Key': 'legacy'}, json=body).status_code == 409
    response = client.post('/v1/requests', headers={**h('alice'), 'Idempotency-Key': 'visit'}, json={**body, 'service_mode': 'shop_visit'})
    assert response.status_code == 201, response.text
    assert response.json()['service_mode'] == 'shop_visit'
    with client.app.state.session_factory() as db:
        item = db.query(Outbox).filter(Outbox.request_id == response.json()['id']).one()
        assert item.payload['service_mode'] == 'shop_visit'
    assert client.post('/v1/requests', headers={**h('alice'), 'Idempotency-Key': 'mobile'}, json={**body, 'service_mode': 'mobile'}).status_code == 422


def test_radius_is_fixed_and_boundary_distance_is_not_service_coverage(clients):
    import math
    from estimoto_plus.discovery_provider import distance_miles, normalize_listing
    client, _ = clients
    setup(client)
    assert client.get('/v1/discovery', headers=h('alice'), params={'radius_miles': '30'}).status_code == 200
    assert client.get('/v1/discovery', headers=h('alice'), params={'radius_miles': 31}).status_code == 422
    assert distance_miles([0, 0], [math.degrees(29.999 / 3958.7613), 0]) < 30
    assert distance_miles([0, 0], [math.degrees(30.001 / 3958.7613), 0]) > 30
    row = normalize_listing(DirectoryStub.shop(44, 'Audi PDR mobile specialist', {'brand': 'Audi', 'operator': 'Audi'}))
    assert row['listed_makes'] == [] and row['mobile_service'] is False and row['specialties'] == ['mechanical']


@pytest.mark.parametrize('bad', [{'remark': 'runtime error', 'elements': []}, {'elements': 'bad'}, {'elements': [None]}])
def test_malformed_or_partial_directory_does_not_claim_complete_search(clients, bad):
    client, _ = clients
    _, stub = setup(client)
    client.app.state.discovery_transport = httpx.MockTransport(lambda r: httpx.Response(200, json=bad) if r.url.host in ('overpass-api.de', 'overpass.private.coffee') else stub(r))
    result = client.get('/v1/discovery', headers=h('alice')).json()
    assert result['status'] == 'unavailable' and result['providers'] == []


def test_expired_public_data_and_unknown_business_location_fail_closed(clients):
    from estimoto_plus.discovery_models import DirectoryCache
    from estimoto_plus.models import now
    client, _ = clients
    _, stub = setup(client)
    identifier = partner(client)
    with client.app.state.session_factory() as db:
        from estimoto_plus.models import Provider
        db.get(Provider, identifier).address = 'Broadway Street'
        db.commit()
    result = client.get('/v1/discovery', headers=h('alice')).json()
    assert identifier not in [p['id'] for p in result['providers']]
    with client.app.state.session_factory() as db:
        for row in db.query(DirectoryCache).filter(DirectoryCache.fetched_at.is_not(None)).all():
            row.fetched_at = now() - timedelta(days=8)
        db.commit()
    stub.fail = True
    result = client.get('/v1/discovery', headers=h('alice')).json()
    assert result['status'] == 'unavailable' and not result['providers']


def test_dedicated_shop_competing_updates_and_saved_shop_advice_never_send(clients):
    from estimoto_plus.models import Outbox
    from estimoto_plus.shop_models import ShopOutbox
    client, delivered = clients
    vehicle, _ = setup(client)
    shop = client.post('/v1/my-shops', headers=h('alice'), json={'name': 'My private garage', 'email': '', 'phone': '3035550100', 'address': ''}).json()['id']
    body = {'vehicle_id': vehicle, 'source': 'my_shop', 'source_id': shop}
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: client.put('/v1/discovery/favorites/mechanical', headers=h('alice'), json=body), range(2)))
    assert all(r.status_code == 200 for r in results)
    answer = client.post('/v1/assistant', headers=h('alice'), json={'message': 'Find a mechanic', 'vehicle_id': vehicle}).json()
    assert answer['intent'] == 'shop_outreach' and shop == answer['dedicated_shop_id']
    with client.app.state.session_factory() as db:
        assert db.query(Outbox).count() == 0 and db.query(ShopOutbox).count() == 0
    assert delivered == []


def test_mode_proof_is_checked_again_before_delivery_and_replay_needs_no_network(clients):
    from estimoto_plus.models import Provider
    client, _ = clients
    vehicle, stub = setup(client)
    identifier = partner(client)
    body = {'vehicle_id': vehicle, 'provider_id': identifier, 'specialty': 'pdr', 'description': 'Dent repair', 'share_contact': True, 'service_mode': 'shop_visit'}
    headers = {**h('alice'), 'Idempotency-Key': 'snapshot'}
    first = client.post('/v1/requests', headers=headers, json=body)
    assert first.status_code == 201
    stub.fail = True
    assert client.post('/v1/requests', headers=headers, json=body).json()['id'] == first.json()['id']
    with client.app.state.session_factory() as db:
        db.get(Provider, identifier).address = 'Moved to another business address CO 99999'
        db.commit()
    client.post('/v1/bridge/outbox/deliver', headers={'X-Bridge-Key': 'bridge-secret'})
    assert client.get('/v1/requests', headers=h('alice')).json()[0]['delivery_status'] == 'failed'


def test_daily_attempt_budget_shared_across_customers_and_postal_codes(clients):
    from estimoto_plus.discovery_models import DirectoryBudget, DirectoryCache
    from estimoto_plus.models import now
    client, _ = clients
    _, stub = setup(client)
    client.app.state.settings.discovery_daily_requests = 1
    assert client.get('/v1/discovery', headers=h('alice')).json()['status'] == 'ready'
    # Cache hits spend neither a request nor body bytes.
    assert client.get('/v1/discovery', headers=h('bob'), params={'postal_code': '80204'}).json()['status'] == 'ready'
    assert client.get('/v1/discovery', headers=h('bob'), params={'postal_code': '80221'}).json()['status'] == 'stale'
    assert len([r for r in stub.calls if r.url.host == 'overpass-api.de']) == 1
    with client.app.state.session_factory() as db:
        daily = db.get(DirectoryBudget, now().date().isoformat())
        assert daily.attempts == 1 and 0 < daily.body_bytes < 2000
        row = db.get(DirectoryCache, 'osm:80204')
        row.fetched_at = now() - timedelta(days=2)
        row.next_attempt_at = now() - timedelta(seconds=1)
        db.commit()
    assert client.get('/v1/discovery', headers=h('alice')).json()['status'] == 'stale'
    assert len([r for r in stub.calls if r.url.host == 'overpass-api.de']) == 1


def test_daily_bytes_count_failed_response_and_stop_at_reserved_bound(clients):
    from estimoto_plus.discovery_models import DirectoryBudget
    from estimoto_plus.models import now
    client, _ = clients
    _, stub = setup(client)
    client.app.state.settings.discovery_daily_bytes = 2048
    attempts = []
    def transport(request):
        if request.url.host == 'api.zippopotam.us':
            return stub(request)
        attempts.append(request)
        return httpx.Response(503, content=b'x' * 10000)
    client.app.state.discovery_transport = httpx.MockTransport(transport)
    assert client.get('/v1/discovery', headers=h('alice')).json()['status'] == 'unavailable'
    assert client.get('/v1/discovery', headers=h('alice'), params={'postal_code': '80221'}).json()['status'] == 'unavailable'
    with client.app.state.session_factory() as db:
        daily = db.get(DirectoryBudget, now().date().isoformat())
        assert daily.attempts == 1 and daily.body_bytes == 2048
    assert len(attempts) == 1


def test_body_budget_reservation_cannot_be_spent_by_concurrent_zip_fetch(clients):
    from threading import Event
    from estimoto_plus.discovery_cache import public_directory
    from estimoto_plus.discovery_models import DirectoryBudget
    from estimoto_plus.models import now
    client, _ = clients
    _, stub = setup(client)
    entered, release = Event(), Event()
    def blocked(request):
        entered.set()
        assert release.wait(5)
        return stub(request)
    settings = client.app.state.settings
    factory = client.app.state.session_factory
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(public_directory, factory, httpx.MockTransport(blocked), '80204', [39.734, -105.0259], settings)
        assert entered.wait(5)
        with factory() as db:
            daily = db.get(DirectoryBudget, now().date().isoformat())
            assert daily.attempts == 1 and daily.body_bytes == 3 * 1024 * 1024
        other = public_directory(factory, httpx.MockTransport(blocked), '80221', [39.82, -105.0259], settings)
        assert other[1] == 'unavailable'
        release.set()
        assert pending.result()[1] == 'ready'
    with factory() as db:
        daily = db.get(DirectoryBudget, now().date().isoformat())
        assert daily.attempts == 1 and daily.body_bytes < 2000


def test_address_requires_location_zip_and_proof_rejects_invalid_coordinates():
    from types import SimpleNamespace
    from estimoto_plus.discovery import address_hash, address_zip, valid_admission
    provider = SimpleNamespace(address='12345 Broadway Denver Colorado', kind='shop')
    assert address_zip(provider) is None
    provider.address = '12345 Broadway Denver CO 80221, USA'
    assert address_zip(provider) == '80221'
    proof = {'postal_code': '80204', 'shop_postal_code': '80221', 'address_hash': address_hash(provider),
             'distance_basis': 'zip_centroid', 'customer_point': [float('nan'), 0], 'shop_point': [0, 0]}
    assert not valid_admission(provider, '80204', 'shop_visit', proof)


def test_starred_public_duplicate_preserves_participating_handoff(clients):
    client, _ = clients
    vehicle, stub = setup(client)
    identifier = partner(client)
    stub.elements = [stub.shop(1, 'Demolition Dent fixture', {
        'phone': '3035550100', 'service:vehicle:pdr': 'yes',
        'addr:housenumber': '1', 'addr:street': 'Example St',
        'addr:city': 'Denver', 'addr:state': 'CO', 'addr:postcode': '80221',
    })]
    client.get('/v1/discovery', headers=h('alice'))
    assert client.put('/v1/discovery/favorites/pdr', headers=h('alice'), json={
        'vehicle_id': vehicle, 'source': 'openstreetmap', 'source_id': 'node:1'}).status_code == 200
    data = client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': vehicle, 'specialty': 'pdr'}).json()
    assert len(data['providers']) == 1
    row = data['providers'][0]
    assert row['id'] == identifier and row['favorite'] and row['request_modes'] == ['shop_visit']
    assert row['specialty_evidence'][0]['basis'] == 'owner_declared'
    assert row['favorite_references'] == [{'vehicle_id': vehicle, 'specialty': 'pdr',
                                          'source': 'openstreetmap', 'source_id': 'node:1'}]
    public_view = client.get('/v1/discovery', headers=h('alice')).json()
    assert all(not p['favorite_references'] for p in public_view['providers'])
    bob_vehicle = client.post('/v1/vehicles', headers=h('bob'), json={'year': 2020, 'make': 'Ford', 'model': 'F-150'}).json()['id']
    other = client.get('/v1/discovery', headers=h('bob'), params={'vehicle_id': bob_vehicle, 'postal_code': '80204'}).json()
    assert all(not p['favorite_references'] for p in other['providers'])
    assert client.delete('/v1/discovery/favorites/pdr', headers=h('alice'), params={'vehicle_id': vehicle}).status_code == 200
    removed = client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': vehicle, 'specialty': 'pdr'}).json()['providers'][0]
    assert not removed['favorite'] and removed['favorite_references'] == []


def test_shared_phone_different_address_keeps_distinct_shop_and_favorite(clients):
    client, _ = clients
    vehicle, stub = setup(client)
    partner_id = partner(client)
    stub.elements = [stub.shop(1, 'Demolition Dent fixture', {
        'phone': '3035550100', 'service:vehicle:pdr': 'yes',
        'addr:housenumber': '99', 'addr:street': 'Other St',
        'addr:city': 'Denver', 'addr:state': 'CO', 'addr:postcode': '80204',
    })]
    client.get('/v1/discovery', headers=h('alice'))
    assert client.put('/v1/discovery/favorites/pdr', headers=h('alice'), json={
        'vehicle_id': vehicle, 'source': 'openstreetmap', 'source_id': 'node:1'}).status_code == 200
    data = client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': vehicle, 'specialty': 'pdr'}).json()
    matches = [row for row in data['providers'] if row['name'] == 'Demolition Dent fixture']
    assert len(matches) == 2
    by_id = {row['id']: row for row in matches}
    assert by_id['osm:node:1']['favorite'] is True
    assert by_id['osm:node:1']['request_modes'] == []
    assert by_id[partner_id]['favorite'] is False
    assert by_id[partner_id]['request_modes'] == ['shop_visit']
    assert by_id[partner_id]['favorite_references'] == []
