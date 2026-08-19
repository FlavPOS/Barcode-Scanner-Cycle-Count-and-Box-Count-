import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

void configureDatabasePlatform() {}

Future<String> resolveDatabasePath() async {
  return join(await getDatabasesPath(), 'barcode_count.db');
}
