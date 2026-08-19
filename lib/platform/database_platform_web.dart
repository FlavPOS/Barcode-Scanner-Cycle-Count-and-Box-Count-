import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

void configureDatabasePlatform() {
  databaseFactory = databaseFactoryFfiWeb;
}

Future<String> resolveDatabasePath() async {
  return 'barcode_count_web.db';
}
