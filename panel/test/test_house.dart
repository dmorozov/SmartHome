import 'dart:io';

import 'package:panel/data/house_loader.dart';
import 'package:panel/domain/house.dart';

/// The shipped House Plan assets, loaded from disk (tests run with the
/// package root as cwd) — so tests exercise the real loader on the real
/// placeholder files.
House loadTestHouse() => loadHouse(
      houseYaml: File('assets/house/house.yaml').readAsStringSync(),
      devicesYaml: File('assets/house/devices.yaml').readAsStringSync(),
    );
