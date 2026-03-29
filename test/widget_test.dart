import 'package:flutter_test/flutter_test.dart';

import 'package:chic_salon/main.dart';

void main() {
  test('ChicSalonApp is instantiable (compile-time smoke test)', () {
    const app = ChicSalonApp();
    expect(app, isA<ChicSalonApp>());
  });
}
