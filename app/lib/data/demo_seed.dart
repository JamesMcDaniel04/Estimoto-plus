import '../domain/models.dart';

Json demoSeed() {
  final now = DateTime.now();
  return {
    'profile': {
      'id': 'demo-customer',
      'name': 'Alex Morgan',
      'email': 'alex@example.com',
      'phone': '',
      'postal_code': '80202',
      'contact_preference': 'email',
    },
    'vehicles': [
      {
        'id': 'demo-audi',
        'nickname': 'My daily driver',
        'year': 2022,
        'make': 'Audi',
        'model': 'Q5',
        // Synthetic identifier with a valid check digit; never sent to a provider.
        'vin': 'ZZZDEMAA3N0000001',
        'mileage': 28450,
        'insurer': '',
        'policy_number': '',
      },
      {
        'id': 'demo-toyota',
        'nickname': 'Weekend plans',
        'year': 2021,
        'make': 'Toyota',
        'model': 'Tacoma',
        'vin': '',
        'mileage': 41200,
        'insurer': '',
        'policy_number': '',
      },
    ],
    'providers': [
      {
        'id': 'demo-dent',
        'name': 'Demo Dent Studio',
        'kind': 'technician',
        'specialties': ['pdr'],
        'postal_codes': ['80202', '80203', '80204'],
        'city': 'Denver, CO',
        'address': '',
        'phone': '',
        'mobile_service': true,
        'accepting_requests': true,
        'description':
            'Paintless dent repair for door dings and hail damage. Mobile service at your home or workplace.',
      },
      {
        'id': 'demo-collision',
        'name': 'Demo Collision Works',
        'kind': 'shop',
        'specialties': ['collision', 'pdr'],
        'postal_codes': ['80202', '80203'],
        'city': 'Denver, CO',
        'address': '',
        'phone': '',
        'mobile_service': false,
        'accepting_requests': true,
        'description':
            'Body repairs, refinishing and help understanding your collision estimate.',
      },
      {
        'id': 'demo-service',
        'name': 'Demo Neighborhood Auto',
        'kind': 'shop',
        'specialties': ['maintenance', 'mechanical'],
        'postal_codes': ['80202', '80203', '80204'],
        'city': 'Denver, CO',
        'address': '',
        'phone': '',
        'mobile_service': false,
        'accepting_requests': true,
        'description':
            'Routine service, inspections and a helpful second opinion about a new noise or warning light.',
      },
    ],
    'estimates': [
      {
        'id': 'demo-estimate',
        'vehicle_id': 'demo-audi',
        'discipline': 'pdr',
        'description': 'Small door ding on the passenger side.',
        'claim_number': '',
        'date_of_loss': '',
        'status': 'ready',
        'delivery_status': 'local_preview',
        'processing_state': 'complete',
        'amount_cents': 32500,
        'provider_id': 'demo-dent',
        'provider_name': 'Demo Dent Studio',
        'updated_at': now.toIso8601String(),
        'photos': [],
      },
      {
        'id': 'demo-collision-estimate',
        'vehicle_id': 'demo-toyota',
        'discipline': 'collision',
        'description': 'Rear bumper repair.',
        'claim_number': '',
        'date_of_loss': '',
        'status': 'approved',
        'delivery_status': 'local_preview',
        'processing_state': 'complete',
        'amount_cents': 148000,
        'provider_id': 'demo-collision',
        'provider_name': 'Demo Collision Works',
        'updated_at': now.toIso8601String(),
        'photos': [],
      },
    ],
    'repairs': [
      {
        'id': 'demo-repair',
        'vehicle_id': 'demo-toyota',
        'provider_name': 'Demo Collision Works',
        'title': 'Rear bumper repair',
        'status': 'Repair in progress',
        'updated_at': now.toIso8601String(),
        'estimated_completion': now
            .add(const Duration(days: 3))
            .toIso8601String()
            .substring(0, 10),
        'stages': [
          {
            'title': 'Estimate approved',
            'status': 'completed',
            'date': now
                .subtract(const Duration(days: 3))
                .toIso8601String()
                .substring(0, 10),
          },
          {
            'title': 'Vehicle checked in',
            'status': 'completed',
            'date': now
                .subtract(const Duration(days: 1))
                .toIso8601String()
                .substring(0, 10),
          },
          {'title': 'Repair in progress', 'status': 'current', 'date': null},
          {'title': 'Quality check', 'status': 'upcoming', 'date': null},
          {'title': 'Ready for pickup', 'status': 'upcoming', 'date': null},
        ],
      },
    ],
    'requests': <Json>[],
    'reminders': [
      {
        'id': 'demo-reminder',
        'vehicle_id': 'demo-audi',
        'title': 'Check your oil service interval',
        'due_date': now
            .add(const Duration(days: 14))
            .toIso8601String()
            .substring(0, 10),
        'due_mileage': 30000,
        'completed': false,
      },
    ],
    'capabilities': {
      'demo': true,
      'live_requests': false,
      'live_estimates': false,
      'carfax': false,
      'youtube_search': false,
    },
  };
}
