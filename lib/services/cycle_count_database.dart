import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class CycleSession {
  const CycleSession({
    required this.id,
    required this.name,
    required this.date,
    required this.startTime,
    this.endTime,
    required this.status,
  });

  final String id;
  final String name;
  final String date;
  final String startTime;
  final String? endTime;
  final String status;

  factory CycleSession.fromMap(Map<String, Object?> map) => CycleSession(
    id: map['id'] as String,
    name: map['name'] as String,
    date: map['date'] as String,
    startTime: map['start_time'] as String,
    endTime: map['end_time'] as String?,
    status: map['status'] as String,
  );
}

class CycleRecord {
  const CycleRecord({
    required this.id,
    required this.sessionId,
    required this.date,
    required this.time,
    required this.barcode,
    required this.qty,
  });

  final int id;
  final String sessionId;
  final String date;
  final String time;
  final String barcode;
  final int qty;

  factory CycleRecord.fromMap(Map<String, Object?> map) => CycleRecord(
    id: map['id'] as int,
    sessionId: map['session_id'] as String,
    date: map['date'] as String,
    time: map['time'] as String,
    barcode: map['barcode'] as String,
    qty: map['qty'] as int,
  );
}

class CycleCountDatabase {
  CycleCountDatabase._();
  static final CycleCountDatabase instance = CycleCountDatabase._();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final path = join(await getDatabasesPath(), 'barcode_count.db');
    _database = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cycle_sessions (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            date TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT,
            status TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cycle_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            date TEXT NOT NULL,
            time TEXT NOT NULL,
            barcode TEXT NOT NULL,
            qty INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE cycle_records RENAME TO cycle_records_old',
          );
          await db.execute('''
            CREATE TABLE cycle_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              date TEXT NOT NULL,
              time TEXT NOT NULL,
              barcode TEXT NOT NULL,
              qty INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            INSERT INTO cycle_records (id, session_id, date, time, barcode, qty)
            SELECT id, session_id, date, time, barcode, qty
            FROM cycle_records_old
          ''');
          await db.execute('DROP TABLE cycle_records_old');
        }
      },
    );
    return _database!;
  }

  Future<CycleSession?> getActiveSession() async {
    final db = await database;
    final rows = await db.query(
      'cycle_sessions',
      where: 'status = ?',
      whereArgs: ['ACTIVE'],
      orderBy: 'start_time DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : CycleSession.fromMap(rows.first);
  }

  Future<CycleSession> createSession(String name, DateTime now) async {
    final db = await database;
    final id = 'CC${now.millisecondsSinceEpoch}';
    final session = CycleSession(
      id: id,
      name: name,
      date: _date(now),
      startTime: _time(now),
      status: 'ACTIVE',
    );
    await db.insert('cycle_sessions', {
      'id': session.id,
      'name': session.name,
      'date': session.date,
      'start_time': session.startTime,
      'end_time': null,
      'status': session.status,
    });
    return session;
  }

  Future<void> finishSession(String sessionId, DateTime now) async {
    final db = await database;
    await db.update(
      'cycle_sessions',
      {'status': 'FINISHED', 'end_time': _time(now)},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<List<CycleRecord>> records(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'cycle_records',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id DESC',
    );
    return rows.map(CycleRecord.fromMap).toList();
  }

  Future<List<Map<String, Object?>>> barcodeSummary(String sessionId) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT
        barcode,
        COUNT(*) AS scan_count,
        SUM(qty) AS total_qty
      FROM cycle_records
      WHERE session_id = ?
      GROUP BY barcode
      ORDER BY MAX(id) DESC
      ''',
      [sessionId],
    );
  }

  Future<List<CycleRecord>> scansForBarcode(
    String sessionId,
    String barcode,
  ) async {
    final db = await database;
    final rows = await db.query(
      'cycle_records',
      where: 'session_id = ? AND barcode = ?',
      whereArgs: [sessionId, barcode],
      orderBy: 'id ASC',
    );
    return rows.map(CycleRecord.fromMap).toList();
  }

  Future<void> insertRecord({
    required String sessionId,
    required String barcode,
    required int qty,
    required DateTime now,
  }) async {
    final db = await database;
    await db.insert('cycle_records', {
      'session_id': sessionId,
      'date': _date(now),
      'time': _time(now),
      'barcode': barcode,
      'qty': qty,
    });
  }

  String _two(int value) => value.toString().padLeft(2, '0');
  String _date(DateTime value) =>
      '${value.year}-${_two(value.month)}-${_two(value.day)}';
  String _time(DateTime value) =>
      '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';
}
