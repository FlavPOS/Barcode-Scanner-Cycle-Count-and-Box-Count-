import 'package:barcode_cycle_count/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('Scanner app launches successfully', (tester) async {
    await tester.pumpWidget(const ScannerApp());
    await tester.pump();

    expect(find.text('SCANNER APP'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });
}
