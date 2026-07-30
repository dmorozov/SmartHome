import 'dart:ui';

import '../domain/house.dart';

/// PLACEHOLDER layout — a plausible two-storey arrangement of the real
/// device fleet (see the root README). Edit footprints and positions to
/// match the actual house; the Dollhouse renders whatever this describes.
///
/// Both floors use an 11 m × 9 m plan. Positions are meters from each
/// Floor's north-west corner.
House demoHouse() {
  return const House(
    name: 'Demo House',
    floors: [
      Floor(
        id: 'ground',
        name: 'Ground Floor',
        level: 0,
        rooms: [
          Room(
            id: 'garage',
            name: 'Garage',
            footprint: Rect.fromLTWH(0, 0, 5, 6),
            devices: [
              Device(
                id: 'garage-door',
                name: 'Garage Door',
                kind: DeviceKind.garageDoor,
                connectivity: Connectivity.cloud, // ratgdo retrofit planned
                position: Offset(2.5, 5.5),
              ),
              Device(
                id: 'ev-charger',
                name: 'Tesla Wall Connector',
                kind: DeviceKind.evCharger,
                connectivity: Connectivity.cloud,
                position: Offset(0.6, 3.0),
              ),
              Device(
                id: 'energy-monitor',
                name: 'Emporia Vue',
                kind: DeviceKind.energyMonitor,
                connectivity: Connectivity.cloud, // ESPHome reflash planned
                position: Offset(4.4, 0.6),
              ),
              Device(
                id: 'cam-garage',
                name: 'Garage Cam',
                kind: DeviceKind.camera,
                connectivity: Connectivity.cloud,
                position: Offset(0.6, 0.6),
              ),
            ],
          ),
          Room(
            id: 'living',
            name: 'Living Room',
            footprint: Rect.fromLTWH(5, 0, 6, 5),
            devices: [
              Device(
                id: 'tv-living',
                name: 'Living Room TV',
                kind: DeviceKind.tv,
                connectivity: Connectivity.local,
                position: Offset(8.0, 0.7),
              ),
              Device(
                id: 'light-living-1',
                name: 'Ceiling Light',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(6.8, 2.4),
              ),
              Device(
                id: 'light-living-2',
                name: 'Reading Lamp',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(9.8, 3.8),
              ),
              Device(
                id: 'outlet-living',
                name: 'Media Outlet',
                kind: DeviceKind.outlet,
                connectivity: Connectivity.local,
                position: Offset(10.4, 0.8),
              ),
              Device(
                id: 'cam-living',
                name: 'Living Cam',
                kind: DeviceKind.camera,
                connectivity: Connectivity.cloud,
                position: Offset(5.6, 4.4),
              ),
            ],
          ),
          Room(
            id: 'kitchen',
            name: 'Kitchen',
            footprint: Rect.fromLTWH(5, 5, 6, 4),
            devices: [
              Device(
                id: 'oven',
                name: 'Oven',
                kind: DeviceKind.oven,
                connectivity: Connectivity.cloud,
                position: Offset(5.7, 8.3),
              ),
              Device(
                id: 'light-kitchen',
                name: 'Kitchen Light',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(8.0, 7.0),
              ),
              Device(
                id: 'feeder-granary',
                name: 'Granary Feeder',
                kind: DeviceKind.feeder,
                connectivity: Connectivity.cloud,
                position: Offset(10.3, 5.7),
              ),
              Device(
                id: 'feeder-petlibro',
                name: 'Petlibro One',
                kind: DeviceKind.feeder,
                connectivity: Connectivity.cloud,
                position: Offset(10.3, 8.3),
              ),
            ],
          ),
          Room(
            id: 'hall',
            name: 'Hall',
            footprint: Rect.fromLTWH(0, 6, 5, 3),
            devices: [
              Device(
                id: 'doorbell',
                name: 'Ring Doorbell',
                kind: DeviceKind.doorbell,
                connectivity: Connectivity.cloud,
                position: Offset(0.5, 7.5),
              ),
              Device(
                id: 'thermostat',
                name: 'Ecobee',
                kind: DeviceKind.thermostat,
                connectivity: Connectivity.local, // HomeKit-controller
                position: Offset(2.5, 6.5),
              ),
              Device(
                id: 'light-hall',
                name: 'Hall Light',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(2.5, 7.9),
              ),
            ],
          ),
        ],
      ),
      Floor(
        id: 'upstairs',
        name: 'Upstairs',
        level: 1,
        rooms: [
          Room(
            id: 'master',
            name: 'Master Bedroom',
            footprint: Rect.fromLTWH(0, 0, 6, 5),
            devices: [
              Device(
                id: 'light-master',
                name: 'Bedroom Light',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(3.0, 2.5),
              ),
              Device(
                id: 'tv-master',
                name: 'Bedroom TV',
                kind: DeviceKind.tv,
                connectivity: Connectivity.local,
                position: Offset(0.7, 2.5),
              ),
              Device(
                id: 'outlet-master',
                name: 'Bedside Outlet',
                kind: DeviceKind.outlet,
                connectivity: Connectivity.local,
                position: Offset(5.4, 0.7),
              ),
            ],
          ),
          Room(
            id: 'office',
            name: 'Office',
            footprint: Rect.fromLTWH(6, 0, 5, 5),
            devices: [
              Device(
                id: 'light-office',
                name: 'Office Light',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(8.5, 2.5),
              ),
              Device(
                id: 'outlet-office',
                name: 'Desk Outlet',
                kind: DeviceKind.outlet,
                connectivity: Connectivity.local,
                position: Offset(10.4, 4.3),
              ),
              Device(
                id: 'cam-office',
                name: 'Office Cam',
                kind: DeviceKind.camera,
                connectivity: Connectivity.cloud,
                position: Offset(6.6, 0.6),
              ),
            ],
          ),
          Room(
            id: 'laundry',
            name: 'Laundry',
            footprint: Rect.fromLTWH(0, 5, 4, 4),
            devices: [
              Device(
                id: 'washer',
                name: 'LG Washer',
                kind: DeviceKind.washer,
                connectivity: Connectivity.cloud,
                position: Offset(0.8, 8.2),
              ),
              Device(
                id: 'dryer',
                name: 'LG Dryer',
                kind: DeviceKind.dryer,
                connectivity: Connectivity.cloud,
                position: Offset(2.0, 8.2),
              ),
              Device(
                id: 'litter-robot',
                name: 'Litter-Robot 5',
                kind: DeviceKind.litterRobot,
                connectivity: Connectivity.cloud,
                position: Offset(3.2, 5.8),
              ),
            ],
          ),
          Room(
            id: 'kids',
            name: 'Kids Bedroom',
            footprint: Rect.fromLTWH(4, 5, 7, 4),
            devices: [
              Device(
                id: 'light-kids',
                name: 'Kids Light',
                kind: DeviceKind.light,
                connectivity: Connectivity.local,
                position: Offset(7.5, 7.0),
              ),
              Device(
                id: 'outlet-kids',
                name: 'Kids Outlet',
                kind: DeviceKind.outlet,
                connectivity: Connectivity.local,
                position: Offset(10.4, 8.3),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
