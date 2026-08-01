import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/device_traits.dart';
import 'package:panel/domain/house.dart';

void main() {
  test('exactly light, outlet, tv and garage door kinds toggle', () {
    expect(
      DeviceKind.values.where((k) => k.toggles).toSet(),
      {
        DeviceKind.light,
        DeviceKind.outlet,
        DeviceKind.tv,
        DeviceKind.garageDoor,
      },
    );
  });
}
