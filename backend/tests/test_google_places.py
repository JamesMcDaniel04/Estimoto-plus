"""Paid directory boundaries: no fabricated expertise, cached content, or unmetered I/O."""
import json
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest
from sqlalchemy import select

from test_discovery import clients, setup
from test_api import h


def place(identifier='nyc-repair', name='City Auto Repair', **extra):
    return {'id': identifier, 'displayName': {'text': name},
            'formattedAddress': '123 W 30th St, New York, NY 10001',
            'location': {'latitude': 40.7484, 'longitude': -73.9967},
            'types': ['car_repair'], 'businessStatus': 'OPERATIONAL',
            'internationalPhoneNumber': '+1 212-555-0100',
            'websiteUri': 'https://repair.example/', **extra}


def configured(client, *, rows=None, status=200):
    vehicle, stub = setup(client)
    settings = client.app.state.settings
    settings.places_enabled = True
    settings.google_places_api_key = 'private-provider-key'
    settings.places_daily_requests = 100
    calls = []
    def respond(request):
        calls.append(request)
        if request.url.host == 'api.zippopotam.us':
            return httpx.Response(200, json={'post code': request.url.path.split('/')[-1],
                'country abbreviation': 'US', 'places': [{'latitude': '40.7484', 'longitude': '-73.9967'}]})
        if request.url.host == 'places.googleapis.com':
            assert request.headers['X-Goog-Api-Key'] == 'private-provider-key'
            data = (rows or [place()])[0] if request.method == 'GET' else {'places': rows if rows is not None else [place()]}
            return httpx.Response(status, json=data)
        return httpx.Response(503)
    client.app.state.discovery_transport = httpx.MockTransport(respond)
    return vehicle, calls


def test_new_york_uses_places_before_public_overpass_and_does_not_cache_content(clients):
    from estimoto_plus.discovery_models import DirectoryCache, PublicListing, PlacesBudget
    client, _ = clients
    vehicle, calls = configured(client)
    for make in ['Audi', 'Toyota', 'Ford']:
        client.put(f'/v1/vehicles/{vehicle}', headers=h('alice'), json={'make': make})
        response = client.get('/v1/discovery', headers=h('alice'), params={'postal_code': '10001', 'vehicle_id': vehicle})
        assert response.status_code == 200
        result = response.json()
        assert result['status'] == 'ready' and result['directory_provider'] == 'google_places'
        row = result['providers'][0]
        assert row['source'] == 'google_places' and row['name'] == 'City Auto Repair'
        assert row['vehicle_match'] == {'status': 'search_relevance', 'make': make, 'basis': 'google_places_query'}
        assert row['listed_makes'] == [] and row['request_modes'] == []
        assert 'private-provider-key' not in response.text
        request = next(r for r in reversed(calls) if r.url.host == 'places.googleapis.com')
        sent = json.loads(request.content)
        assert make in sent['textQuery'] and '10001' in sent['textQuery']
        assert sent['includedType'] == 'car_repair' and sent['strictTypeFiltering'] is True
        assert 'alice' not in str(request.headers) + request.content.decode()
        assert 'locationBias' in sent and '*' not in request.headers['X-Goog-FieldMask']
    assert not any('overpass' in r.url.host for r in calls)
    with client.app.state.session_factory() as db:
        assert not db.scalars(select(PublicListing)).all()
        assert 'City Auto Repair' not in str([r.value for r in db.scalars(select(DirectoryCache)).all()])
        assert db.scalars(select(PlacesBudget)).one().requests == 3
    assert client.get('/v1/bootstrap', headers=h('alice')).json()['profile']['postal_code'] == '80204'


def test_places_excludes_closed_outside_radius_and_non_repair_listings(clients):
    client, _ = clients
    vehicle, _ = configured(client, rows=[place(), place('closed', businessStatus='CLOSED_PERMANENTLY'),
        place('far', location={'latitude': 39.7, 'longitude': -105}), place('cafe', types=['cafe']),
        {'id': 'bad', 'displayName': {'text': 'Broken'}}])
    result = client.get('/v1/discovery', headers=h('alice'), params={'postal_code': '10001', 'vehicle_id': vehicle}).json()
    assert [r['source_id'] for r in result['providers']] == ['nyc-repair']


def test_places_name_query_is_not_re_filtered_against_name_only(clients):
    client, _ = clients
    vehicle, calls = configured(client)
    result = client.get('/v1/discovery', headers=h('alice'), params={
        'postal_code': '10001', 'vehicle_id': vehicle, 'q': 'European diagnostics', 'make_only': True}).json()
    assert result['providers'][0]['source_id'] == 'nyc-repair'
    assert 'European diagnostics' in json.loads(calls[-1].content)['textQuery']


def test_google_favorite_is_only_a_place_id_and_validates_live_identity(clients):
    from estimoto_plus.discovery_models import DedicatedShop, PublicListing
    client, _ = clients
    vehicle, calls = configured(client)
    body = {'vehicle_id': vehicle, 'source': 'google_places', 'source_id': 'nyc-repair'}
    assert client.put('/v1/discovery/favorites/mechanical', headers=h('alice'), json=body).status_code == 200
    count = len(calls)
    assert client.put('/v1/discovery/favorites/mechanical', headers=h('bob'), json=body).status_code == 404
    assert len(calls) == count
    bad = {**body, 'source_id': '../api-keys'}
    count = len(calls)
    assert client.put('/v1/discovery/favorites/mechanical', headers=h('alice'), json=bad).status_code == 422
    assert len(calls) == count
    with client.app.state.session_factory() as db:
        saved = db.scalars(select(DedicatedShop)).one()
        assert saved.source_id == 'nyc-repair'
        assert not db.scalars(select(PublicListing)).all()
    assert client.delete('/v1/discovery/favorites/mechanical', headers=h('alice'), params={'vehicle_id': vehicle}).status_code == 200


@pytest.mark.parametrize('change', ['deleted', 'reassigned'])
def test_google_favorite_rechecks_vehicle_after_unlocked_provider_io(clients, change):
    from estimoto_plus.discovery_models import DedicatedShop, PlacesBudget
    from estimoto_plus.models import Vehicle
    client, _ = clients
    vehicle, _ = configured(client)
    assert client.get('/v1/bootstrap', headers=h('bob')).status_code == 200
    calls = []

    def respond(request):
        calls.append(request)
        assert request.url.path == '/v1/places/nyc-repair'
        # A separate writer must be able to finish while Google is responding.
        # The favorite must then use fresh ownership, not its pre-I/O object.
        with client.app.state.session_factory() as db:
            row = db.get(Vehicle, vehicle)
            if change == 'deleted':
                db.delete(row)
            else:
                row.customer_id = 'bob-id'
            db.commit()
        return httpx.Response(200, json=place())

    client.app.state.discovery_transport = httpx.MockTransport(respond)
    response = client.put('/v1/discovery/favorites/mechanical', headers=h('alice'), json={
        'vehicle_id': vehicle, 'source': 'google_places', 'source_id': 'nyc-repair'})
    assert response.status_code == 404
    assert len(calls) == 1
    with client.app.state.session_factory() as db:
        assert not db.scalars(select(DedicatedShop)).all()
        assert db.scalars(select(PlacesBudget)).one().requests == 1


def test_google_favorite_failed_verification_preserves_choice_and_charges_budget(clients):
    from estimoto_plus.discovery_models import DedicatedShop, DirectoryCache, PlacesBudget
    client, _ = clients
    vehicle, calls = configured(client, status=503)
    with client.app.state.session_factory() as db:
        db.add(DedicatedShop(customer_id='alice-id', vehicle_id=vehicle, specialty='mechanical',
                             source='google_places', source_id='previous-shop'))
        db.commit()
    response = client.put('/v1/discovery/favorites/mechanical', headers=h('alice'), json={
        'vehicle_id': vehicle, 'source': 'google_places', 'source_id': 'nyc-repair'})
    assert response.status_code == 503
    assert len(calls) == 1
    with client.app.state.session_factory() as db:
        assert db.scalars(select(DedicatedShop)).one().source_id == 'previous-shop'
        assert db.scalars(select(PlacesBudget)).one().requests == 1
        assert db.get(DirectoryCache, 'places:cooldown') is not None


def test_places_failure_has_cooldown_and_public_fallback(clients):
    client, _ = clients
    _, calls = configured(client, status=403)
    for _ in range(2):
        assert client.get('/v1/discovery', headers=h('alice'), params={'postal_code': '10001'}).json()['status'] == 'unavailable'
    assert sum(r.url.host == 'places.googleapis.com' for r in calls) == 1


def test_places_budget_is_shared_atomic_and_counts_failed_attempts(clients):
    from estimoto_plus.google_places import reserve_request
    from estimoto_plus.discovery_provider import DirectoryUnavailable
    from estimoto_plus.discovery_models import PlacesBudget
    client, _ = clients
    configured(client)
    client.app.state.settings.places_daily_requests = 3
    def reserve(_):
        try:
            reserve_request(client.app.state.session_factory, client.app.state.settings)
            return True
        except DirectoryUnavailable:
            return False
    with ThreadPoolExecutor(max_workers=8) as pool:
        assert sum(pool.map(reserve, range(16))) == 3
    with client.app.state.session_factory() as db:
        assert db.scalars(select(PlacesBudget)).one().requests == 3


def test_foreign_vehicle_and_demo_never_reach_places(clients):
    client, _ = clients
    vehicle, calls = configured(client)
    assert client.get('/v1/discovery', headers=h('bob'), params={'vehicle_id': vehicle}).status_code == 404
    assert calls == []


def test_places_can_recover_a_failed_public_zip_service_without_caching_google_coordinates(clients):
    from estimoto_plus.discovery_models import DirectoryCache
    client, _ = clients
    vehicle, _ = configured(client)
    calls = []
    def respond(request):
        calls.append(request)
        if request.url.host != 'places.googleapis.com':
            return httpx.Response(503)
        body = json.loads(request.content)
        if body['textQuery'] == '10001, USA':
            return httpx.Response(200, json={'places': [{'location': {'latitude': 40.7484, 'longitude': -73.9967},
                'types': ['postal_code'], 'addressComponents': [
                    {'types': ['postal_code'], 'shortText': '10001'}, {'types': ['country'], 'shortText': 'US'}]}]})
        return httpx.Response(200, json={'places': [place()]})
    client.app.state.discovery_transport = httpx.MockTransport(respond)
    result = client.get('/v1/discovery', headers=h('alice'), params={'postal_code': '10001', 'vehicle_id': vehicle}).json()
    assert result['status'] == 'ready' and len(result['providers']) == 1
    assert sum(r.url.host == 'places.googleapis.com' for r in calls) == 2
    with client.app.state.session_factory() as db:
        assert db.get(DirectoryCache, 'zip:10001').value == {}


def test_places_network_failure_and_redirect_do_not_leak_credentials(clients, caplog):
    from estimoto_plus.google_places import search_places
    from estimoto_plus.discovery_provider import DirectoryUnavailable
    client, _ = clients
    configured(client)
    calls = []
    def redirect(request):
        calls.append(request)
        return httpx.Response(302, headers={'location': 'https://other.example/secret'})
    with pytest.raises(DirectoryUnavailable):
        search_places(client.app.state.session_factory, httpx.MockTransport(redirect),
                      client.app.state.settings, '10001', [40.7484, -73.9967])
    assert len(calls) == 1 and calls[0].url.host == 'places.googleapis.com'
    assert 'private-provider-key' not in caplog.text


def test_places_budget_exhaustion_keeps_fresh_public_results(clients):
    client, _ = clients
    vehicle, stub = setup(client)
    assert client.get('/v1/discovery', headers=h('alice')).json()['status'] == 'ready'
    client.app.state.settings.places_enabled = True
    client.app.state.settings.google_places_api_key = 'private-provider-key'
    client.app.state.settings.places_daily_requests = 0
    before = len(stub.calls)
    result = client.get('/v1/discovery', headers=h('alice'), params={'vehicle_id': vehicle}).json()
    assert result['status'] == 'ready' and result['directory_provider'] == 'public_sources'
    assert len(result['providers']) == 2 and len(stub.calls) == before


@pytest.mark.parametrize('body', [b'not json', b'[]', b'{"places": {}}', b'{"places":'+b' '*1100000+b'[]}'])
def test_places_malformed_and_oversize_response_is_bounded(clients, body):
    from estimoto_plus.google_places import search_places
    from estimoto_plus.discovery_provider import DirectoryUnavailable
    client, _ = clients
    configured(client)
    with pytest.raises(DirectoryUnavailable):
        search_places(client.app.state.session_factory, httpx.MockTransport(lambda _: httpx.Response(200, content=body)),
            client.app.state.settings, '10001', [40.7484, -73.9967], make='Toyota')
