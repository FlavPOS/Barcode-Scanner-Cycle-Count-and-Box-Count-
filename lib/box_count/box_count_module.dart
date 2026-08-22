import 'dart:async';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';

import '../platform/database_platform.dart';
import '../platform/file_download.dart';

String _two(int v) => v.toString().padLeft(2, '0');
String _date(DateTime v) => '${v.year}-${_two(v.month)}-${_two(v.day)}';
String _time(DateTime v) =>
    '${_two(v.hour)}:${_two(v.minute)}:${_two(v.second)}';
String _clean(Object? value) => value?.toString().trim() ?? '';

class ExpectedBox {
  final String initial;
  final String scontainer;
  const ExpectedBox({required this.initial, required this.scontainer});
}

class BoxUploadResult {
  final String fileName;
  final List<ExpectedBox> boxes;
  final List<String> errors;
  final List<String> duplicates;
  const BoxUploadResult({
    required this.fileName,
    required this.boxes,
    required this.errors,
    required this.duplicates,
  });
  bool get valid => errors.isEmpty && duplicates.isEmpty && boxes.isNotEmpty;
  Map<String, int> get byType {
    final out = <String, int>{};
    for (final row in boxes) {
      out[row.initial] = (out[row.initial] ?? 0) + 1;
    }
    return out;
  }
}

class BoxSession {
  final String id;
  final String name;
  final String date;
  final String startTime;
  final String status;
  final String? endTime;
  final String? fileName;
  final bool continuous;
  const BoxSession({
    required this.id,
    required this.name,
    required this.date,
    required this.startTime,
    required this.status,
    required this.continuous,
    this.endTime,
    this.fileName,
  });
  factory BoxSession.fromMap(Map<String, Object?> m) => BoxSession(
    id: m['id'] as String,
    name: m['name'] as String,
    date: m['date'] as String,
    startTime: m['start_time'] as String,
    endTime: m['end_time'] as String?,
    status: m['status'] as String,
    continuous: (m['continuous'] as int) == 1,
    fileName: m['file_name'] as String?,
  );
  BoxSession activeCopy() => BoxSession(
    id: id,
    name: name,
    date: date,
    startTime: startTime,
    status: 'ACTIVE',
    continuous: continuous,
    fileName: fileName,
  );
}

class BoxRecord {
  final int id;
  final String sessionId;
  final String initial;
  final String barcode;
  final String date;
  final String time;
  const BoxRecord({
    required this.id,
    required this.sessionId,
    required this.initial,
    required this.barcode,
    required this.date,
    required this.time,
  });
  factory BoxRecord.fromMap(Map<String, Object?> m) => BoxRecord(
    id: m['id'] as int,
    sessionId: m['session_id'] as String,
    initial: (m['initial'] as String?) ?? '',
    barcode: m['barcode'] as String,
    date: m['scan_date'] as String,
    time: m['scan_time'] as String,
  );
}

enum BoxScanState { valid, invalid, duplicate }

class BoxScanResult {
  final BoxScanState state;
  final String barcode;
  final String? initial;
  const BoxScanResult(this.state, this.barcode, [this.initial]);
  String get title => switch (state) {
    BoxScanState.valid => 'Valid Box Scanned',
    BoxScanState.invalid => 'Invalid Box',
    BoxScanState.duplicate => 'Already Scanned',
  };
  Color get color => switch (state) {
    BoxScanState.valid => Colors.green,
    BoxScanState.invalid => Colors.red,
    BoxScanState.duplicate => Colors.orange,
  };
}

class BoxDb {
  BoxDb._();
  static final instance = BoxDb._();
  Database? _db;
  Future<Database> get db async {
    if (_db != null) return _db!;
    final root = await resolveDatabasePath();
    _db = await databaseFactory.openDatabase(
      '${root}_boxes',
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: _create,
        onUpgrade: _upgrade,
      ),
    );
    return _db!;
  }

  Future<void> _create(Database db, int version) async {
    await db.execute(
      'CREATE TABLE box_sessions(id TEXT PRIMARY KEY,name TEXT NOT NULL,date TEXT NOT NULL,start_time TEXT NOT NULL,end_time TEXT,status TEXT NOT NULL,continuous INTEGER NOT NULL,file_name TEXT)',
    );
    await db.execute(
      'CREATE TABLE expected_boxes(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,initial TEXT NOT NULL,scontainer TEXT NOT NULL,UNIQUE(session_id,scontainer))',
    );
    await db.execute(
      'CREATE TABLE box_records(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,initial TEXT NOT NULL,barcode TEXT NOT NULL,scan_date TEXT NOT NULL,scan_time TEXT NOT NULL,UNIQUE(session_id,barcode))',
    );
    await db.execute(
      'CREATE TABLE box_attempts(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,barcode TEXT NOT NULL,result TEXT NOT NULL,attempt_date TEXT NOT NULL,attempt_time TEXT NOT NULL)',
    );
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute('ALTER TABLE box_sessions ADD COLUMN file_name TEXT');
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE box_records ADD COLUMN initial TEXT NOT NULL DEFAULT ''",
        );
      } catch (_) {}
      await db.execute(
        'CREATE TABLE IF NOT EXISTS expected_boxes(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,initial TEXT NOT NULL,scontainer TEXT NOT NULL,UNIQUE(session_id,scontainer))',
      );
      await db.execute(
        'CREATE TABLE IF NOT EXISTS box_attempts(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,barcode TEXT NOT NULL,result TEXT NOT NULL,attempt_date TEXT NOT NULL,attempt_time TEXT NOT NULL)',
      );
    }
  }

  Future<BoxSession> _createFromUpload(
    String name,
    bool continuous,
    BoxUploadResult upload, {
    required String status,
  }) async {
    final now = DateTime.now();
    final session = BoxSession(
      id: 'BC${now.millisecondsSinceEpoch}',
      name: name,
      date: _date(now),
      startTime: _time(now),
      status: status,
      continuous: continuous,
      fileName: upload.fileName,
    );
    final database = await db;
    await database.transaction((txn) async {
      if (status == 'ACTIVE') {
        await txn.update(
          'box_sessions',
          {'status': 'FINISHED'},
          where: 'status = ?',
          whereArgs: ['ACTIVE'],
        );
      }
      await txn.insert('box_sessions', {
        'id': session.id,
        'name': session.name,
        'date': session.date,
        'start_time': session.startTime,
        'end_time': null,
        'status': status,
        'continuous': continuous ? 1 : 0,
        'file_name': upload.fileName,
      });
      final batch = txn.batch();
      for (final row in upload.boxes) {
        batch.insert('expected_boxes', {
          'session_id': session.id,
          'initial': row.initial,
          'scontainer': row.scontainer,
        });
      }
      await batch.commit(noResult: true);
    });
    return session;
  }

  Future<BoxSession> createSession(
    String name,
    bool continuous,
    BoxUploadResult upload,
  ) => _createFromUpload(name, continuous, upload, status: 'ACTIVE');

  Future<BoxSession> saveBoxListForLater(
    String name,
    bool continuous,
    BoxUploadResult upload,
  ) => _createFromUpload(name, continuous, upload, status: 'DRAFT');

  Future<void> startSavedSession(String id) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.update(
        'box_sessions',
        {'status': 'FINISHED'},
        where: 'status = ? AND id != ?',
        whereArgs: ['ACTIVE', id],
      );
      await txn.update(
        'box_sessions',
        {'status': 'ACTIVE', 'end_time': null},
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<List<BoxSession>> sessions([String query = '']) async {
    final database = await db;
    if (query.trim().isEmpty) {
      return (await database.query(
        'box_sessions',
        orderBy: 'date DESC,start_time DESC',
      )).map(BoxSession.fromMap).toList();
    }
    final p = '%${query.trim()}%';
    final rows = await database.rawQuery(
      'SELECT DISTINCT s.* FROM box_sessions s LEFT JOIN expected_boxes e ON e.session_id=s.id LEFT JOIN box_records r ON r.session_id=s.id LEFT JOIN box_attempts a ON a.session_id=s.id WHERE s.id LIKE ? OR s.name LIKE ? OR s.date LIKE ? OR s.status LIKE ? OR s.file_name LIKE ? OR e.scontainer LIKE ? OR r.barcode LIKE ? OR a.barcode LIKE ? ORDER BY s.date DESC,s.start_time DESC',
      [p, p, p, p, p, p, p, p],
    );
    return rows.map(BoxSession.fromMap).toList();
  }

  Future<List<BoxRecord>> records(String id) async => (await (await db).query(
    'box_records',
    where: 'session_id=?',
    whereArgs: [id],
    orderBy: 'id DESC',
  )).map(BoxRecord.fromMap).toList();
  Future<List<ExpectedBox>> expected(
    String id, {
    String search = '',
    String? initial,
    bool unscannedOnly = false,
  }) async {
    final database = await db;
    final where = <String>['e.session_id=?'];
    final args = <Object?>[id];
    if (search.trim().isNotEmpty) {
      where.add('e.scontainer LIKE ?');
      args.add('%${search.trim()}%');
    }
    if (initial != null && initial.isNotEmpty) {
      where.add('e.initial=?');
      args.add(initial);
    }
    if (unscannedOnly) where.add('r.id IS NULL');
    final rows = await database.rawQuery(
      'SELECT e.initial,e.scontainer FROM expected_boxes e LEFT JOIN box_records r ON r.session_id=e.session_id AND r.barcode=e.scontainer WHERE ${where.join(' AND ')} ORDER BY e.initial,e.scontainer',
      args,
    );
    return rows
        .map(
          (m) => ExpectedBox(
            initial: m['initial'] as String,
            scontainer: m['scontainer'] as String,
          ),
        )
        .toList();
  }

  Future<Map<String, Map<String, int>>> summary(String id) async {
    final rows = await (await db).rawQuery(
      'SELECT e.initial,COUNT(*) expected,SUM(CASE WHEN r.id IS NULL THEN 0 ELSE 1 END) actual FROM expected_boxes e LEFT JOIN box_records r ON r.session_id=e.session_id AND r.barcode=e.scontainer WHERE e.session_id=? GROUP BY e.initial ORDER BY e.initial',
      [id],
    );
    return {
      for (final r in rows)
        r['initial'] as String: {
          'expected': (r['expected'] as num).toInt(),
          'actual': (r['actual'] as num).toInt(),
        },
    };
  }

  Future<int> attemptCount(String id, String result) async =>
      Sqflite.firstIntValue(
        await (await db).rawQuery(
          'SELECT COUNT(*) FROM box_attempts WHERE session_id=? AND result=?',
          [id, result],
        ),
      ) ??
      0;
  Future<BoxScanResult> scan(String id, String raw) async {
    final code = raw.trim();
    final database = await db;
    final now = DateTime.now();
    final match = await database.query(
      'expected_boxes',
      columns: ['initial'],
      where: 'session_id=? AND scontainer=?',
      whereArgs: [id, code],
      limit: 1,
    );
    if (match.isEmpty) {
      await _attempt(database, id, code, 'INVALID', now);
      return BoxScanResult(BoxScanState.invalid, code);
    }
    final exists =
        Sqflite.firstIntValue(
          await database.rawQuery(
            'SELECT COUNT(*) FROM box_records WHERE session_id=? AND barcode=?',
            [id, code],
          ),
        ) ??
        0;
    if (exists > 0) {
      await _attempt(database, id, code, 'DUPLICATE', now);
      return BoxScanResult(
        BoxScanState.duplicate,
        code,
        match.first['initial'] as String,
      );
    }
    final initial = match.first['initial'] as String;
    await database.insert('box_records', {
      'session_id': id,
      'initial': initial,
      'barcode': code,
      'scan_date': _date(now),
      'scan_time': _time(now),
    });
    await _attempt(database, id, code, 'VALID', now);
    return BoxScanResult(BoxScanState.valid, code, initial);
  }

  Future<void> _attempt(
    Database db,
    String id,
    String code,
    String result,
    DateTime now,
  ) => db.insert('box_attempts', {
    'session_id': id,
    'barcode': code,
    'result': result,
    'attempt_date': _date(now),
    'attempt_time': _time(now),
  });
  Future<void> finish(String id) async {
    final now = DateTime.now();
    await (await db).update(
      'box_sessions',
      {'status': 'FINISHED', 'end_time': _time(now)},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> reopen(String id) async {
    final database = await db;
    await database.update(
      'box_sessions',
      {'status': 'FINISHED'},
      where: 'status=? AND id!=?',
      whereArgs: ['ACTIVE', id],
    );
    await database.update(
      'box_sessions',
      {'status': 'ACTIVE', 'end_time': null},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> remove(int id) async =>
      (await db).delete('box_records', where: 'id=?', whereArgs: [id]);
}

Future<BoxUploadResult?> pickAndValidateBoxList() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
  if (files.isEmpty) return null;
  final file = files.first;

  if (!file.name.toLowerCase().endsWith('.xlsx')) {
    return BoxUploadResult(
      fileName: file.name,
      boxes: const [],
      errors: const ['Please select a valid .xlsx Excel file.'],
      duplicates: const [],
    );
  }

  Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    return BoxUploadResult(
      fileName: file.name,
      boxes: const [],
      errors: const ['The selected file could not be read.'],
      duplicates: const [],
    );
  }
  try {
    final workbook = Excel.decodeBytes(bytes);
    Sheet? sheet;
    for (final name in workbook.tables.keys) {
      if ((workbook.tables[name]?.maxRows ?? 0) > 0) {
        sheet = workbook.tables[name];
        break;
      }
    }
    if (sheet == null) {
      return BoxUploadResult(
        fileName: file.name,
        boxes: const [],
        errors: const ['The workbook does not contain a readable worksheet.'],
        duplicates: const [],
      );
    }
    int header = -1, initialCol = -1, containerCol = -1;
    for (var r = 0; r < sheet.maxRows && r < 20; r++) {
      for (var c = 0; c < sheet.maxColumns; c++) {
        final value = _clean(
          sheet
              .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
              .value,
        ).toUpperCase();
        if (value == 'INITIAL') initialCol = c;
        if (value == 'SCONTAINER') containerCol = c;
      }
      if (initialCol >= 0 && containerCol >= 0) {
        header = r;
        break;
      }
    }
    if (header < 0) {
      return BoxUploadResult(
        fileName: file.name,
        boxes: const [],
        errors: const [
          'Required columns INITIAL and SCONTAINER were not found.',
        ],
        duplicates: const [],
      );
    }
    final boxes = <ExpectedBox>[],
        errors = <String>[],
        seen = <String>{},
        duplicates = <String>{};
    for (var r = header + 1; r < sheet.maxRows; r++) {
      final initial = _clean(
        sheet
            .cell(
              CellIndex.indexByColumnRow(columnIndex: initialCol, rowIndex: r),
            )
            .value,
      ).toUpperCase();
      final code = _clean(
        sheet
            .cell(
              CellIndex.indexByColumnRow(
                columnIndex: containerCol,
                rowIndex: r,
              ),
            )
            .value,
      ).toUpperCase();
      if (initial.isEmpty && code.isEmpty) continue;
      if (initial.isEmpty || code.isEmpty) {
        errors.add('Row ${r + 1}: INITIAL and SCONTAINER are both required.');
        continue;
      }
      if (!seen.add(code)) {
        duplicates.add(code);
        continue;
      }
      boxes.add(ExpectedBox(initial: initial, scontainer: code));
    }
    if (boxes.isEmpty) errors.add('No valid box records were found.');
    return BoxUploadResult(
      fileName: file.name,
      boxes: boxes,
      errors: errors,
      duplicates: duplicates.toList()..sort(),
    );
  } catch (e) {
    return BoxUploadResult(
      fileName: file.name,
      boxes: const [],
      errors: ['Unable to read the Excel file: $e'],
      duplicates: const [],
    );
  }
}

class BoxCountHome extends StatefulWidget {
  const BoxCountHome({super.key});
  @override
  State<BoxCountHome> createState() => _BoxCountHomeState();
}

class _BoxCountHomeState extends State<BoxCountHome> {
  BoxUploadResult? upload;
  bool loading = false;
  Future<void> chooseFile() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final next = await pickAndValidateBoxList();
      if (!mounted) return;
      if (next != null) {
        setState(() => upload = next);
        if (!next.valid) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                next.errors.isNotEmpty
                    ? next.errors.first
                    : 'Duplicate SCONTAINER values were found.',
              ),
            ),
          );
        }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open the Excel file: $error')),
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> saveForLater() async {
    if (upload == null || !upload!.valid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please upload a valid Box List Excel file before saving.',
          ),
        ),
      );
      return;
    }

    var name = '';
    var continuous = true;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('SAVE BOX LIST FOR LATER'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                onChanged: (value) => name = value,
                decoration: const InputDecoration(
                  labelText: 'Session Name',
                  hintText: 'Example: Tomorrow Morning Delivery',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: continuous,
                onChanged: (value) => setLocal(() => continuous = value),
                title: const Text('Continuous Scanning'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );

    if (save != true || name.trim().isEmpty || !mounted) return;
    final session = await BoxDb.instance.saveBoxListForLater(
      name.trim(),
      continuous,
      upload!,
    );
    if (!mounted) return;
    setState(() => upload = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${session.name} saved. Open Box Count History when ready to scan.',
        ),
      ),
    );
  }

  Future<void> start() async {
    if (upload == null || !upload!.valid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please upload the Box List Excel file before starting the box count.',
          ),
        ),
      );
      return;
    }
    var name = '';
    var continuous = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('START BOX COUNT'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                onChanged: (v) => name = v,
                decoration: const InputDecoration(
                  labelText: 'Session Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: continuous,
                onChanged: (v) => setLocal(() => continuous = v),
                title: const Text('Continuous Scanning'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('START'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || name.trim().isEmpty || !mounted) return;
    final session = await BoxDb.instance.createSession(
      name.trim(),
      continuous,
      upload!,
    );
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BoxCountScreen(session: session)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BOX COUNT')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            FilledButton.icon(
              onPressed: loading ? null : chooseFile,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('UPLOAD BOX LIST'),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BoxHistory()),
              ),
              icon: const Icon(Icons.history),
              label: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('VIEW BOX COUNT HISTORY'),
              ),
            ),
            if (upload != null) ...[
              const SizedBox(height: 16),
              _UploadCard(upload: upload!),
              const SizedBox(height: 16),
              _ExpectedTable(byType: upload!.byType),
            ],
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: upload?.valid == true ? saveForLater : null,
              icon: const Icon(Icons.save_outlined),
              label: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('SAVE BOX LIST FOR LATER'),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: upload?.valid == true ? start : null,
              icon: const Icon(Icons.play_arrow),
              label: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('START BOX COUNT'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _UploadCard extends StatelessWidget {
  final BoxUploadResult upload;
  const _UploadCard({required this.upload});
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(upload.fileName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('Total Expected Boxes: ${upload.boxes.length}'),
          ...upload.byType.entries.map(
            (e) => Text('Total ${e.key}: ${e.value}'),
          ),
          if (upload.valid)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'Excel file validated successfully.',
                style: TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (upload.duplicates.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${upload.duplicates.length} duplicate SCONTAINER values found.',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
            ...upload.duplicates
                .take(10)
                .map((e) => Text(e, style: const TextStyle(color: Colors.red))),
          ],
          if (upload.errors.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...upload.errors
                .take(10)
                .map((e) => Text(e, style: const TextStyle(color: Colors.red))),
          ],
        ],
      ),
    ),
  );
}

class _ExpectedTable extends StatelessWidget {
  final Map<String, int> byType;
  const _ExpectedTable({required this.byType});
  @override
  Widget build(BuildContext context) {
    final total = byType.values.fold(0, (a, b) => a + b);
    return _ResponsiveTable(
      headers: const ['Case Type', 'Expected', 'Actual Scanned', 'Unscanned'],
      rows: [
        ...byType.entries.map((e) => [e.key, '${e.value}', '0', '${e.value}']),
        ['Total', '$total', '0', '$total'],
      ],
      boldLast: true,
    );
  }
}

class BoxCountScreen extends StatefulWidget {
  final BoxSession session;
  const BoxCountScreen({super.key, required this.session});
  @override
  State<BoxCountScreen> createState() => _BoxCountScreenState();
}

class _BoxCountScreenState extends State<BoxCountScreen> {
  List<BoxRecord> records = [];
  Map<String, Map<String, int>> summary = {};
  int invalid = 0, duplicates = 0;
  bool get continuous => widget.session.continuous;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await BoxDb.instance.records(widget.session.id),
        s = await BoxDb.instance.summary(widget.session.id),
        i = await BoxDb.instance.attemptCount(widget.session.id, 'INVALID'),
        d = await BoxDb.instance.attemptCount(widget.session.id, 'DUPLICATE');
    if (mounted) {
      setState(() {
        records = r;
        summary = s;
        invalid = i;
        duplicates = d;
      });
    }
  }

  int get expected =>
      summary.values.fold(0, (a, e) => a + (e['expected'] ?? 0));
  int get actual => records.length;
  int get unscanned => expected - actual;
  double get progress => expected == 0 ? 0 : actual / expected;
  Future<BoxScanResult> accept(String code) async {
    final result = await BoxDb.instance.scan(widget.session.id, code);
    await load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: result.color,
          content: Text(
            result.state == BoxScanState.valid
                ? '${result.title}\nCase Type: ${result.initial}\nBox: ${result.barcode}'
                : result.state == BoxScanState.invalid
                ? '${result.title}\nThis SCONTAINER is not included in the uploaded Box List.'
                : '${result.title}\nThis box was already scanned and cannot be counted twice.',
          ),
        ),
      );
    }
    return result;
  }

  Future<void> camera() async {
    if (continuous) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ContinuousBoxScanner(onCode: accept)),
      );
    } else {
      final code = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const SingleBoxScanner()),
      );
      if (code != null) await accept(code);
    }
    await load();
  }

  Future<void> manual() async {
    var value = '';
    final code = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('BOX BARCODE'),
        content: TextField(
          autofocus: true,
          onChanged: (v) => value = v,
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, value.trim().toUpperCase()),
            child: const Text('VALIDATE'),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) await accept(code);
  }

  Future<void> finish() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('BOX COUNT SUMMARY'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Expected: $expected'),
            Text('Actual Scanned: $actual'),
            Text('Unscanned: $unscanned'),
            Text('Completion: ${(progress * 100).round()}%'),
            if (unscanned > 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'There are still $unscanned unscanned boxes. Do you want to finish this Box Count session?',
                  style: const TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('CONTINUE SCANNING'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('FINISH BOX COUNT'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await BoxDb.instance.finish(widget.session.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
        actions: [
          IconButton(
            onPressed: finish,
            tooltip: 'Finish Box Count',
            icon: const Icon(Icons.done),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: camera,
        icon: const Icon(Icons.qr_code_scanner),
        label: Text(continuous ? 'CONTINUOUS SCAN' : 'SCAN BOX'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              _ProgressCard(
                expected: expected,
                actual: actual,
                unscanned: unscanned,
                progress: progress,
                duplicates: duplicates,
                invalid: invalid,
              ),
              const SizedBox(height: 12),
              _LiveSummary(summary: summary),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: manual,
                    icon: const Icon(Icons.keyboard),
                    label: const Text('MANUAL VALIDATION'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            UnscannedScreen(session: widget.session),
                      ),
                    ),
                    icon: const Icon(Icons.inventory),
                    label: const Text('VIEW UNSCANNED BOXES'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...records.map(
                (record) => Card(
                  child: ListTile(
                    title: Text(record.barcode),
                    subtitle: Text('${record.date} ${record.time}'),
                    leading: CircleAvatar(child: Text(record.initial)),
                    onLongPress: () async {
                      final remove = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text(record.barcode),
                          content: const Text('Remove this scanned box?'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('CANCEL'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('REMOVE'),
                            ),
                          ],
                        ),
                      );
                      if (remove == true) {
                        await BoxDb.instance.remove(record.id);
                        await load();
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final int expected, actual, unscanned, duplicates, invalid;
  final double progress;
  const _ProgressCard({
    required this.expected,
    required this.actual,
    required this.unscanned,
    required this.progress,
    required this.duplicates,
    required this.invalid,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Total Progress', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(
            '$actual / $expected Scanned - ${(progress * 100).round()}%',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            minHeight: 12,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              Text('Expected: $expected'),
              Text('Actual: $actual'),
              Text('Unscanned: $unscanned'),
              Text('Duplicates: $duplicates'),
              Text('Invalid: $invalid'),
            ],
          ),
        ],
      ),
    ),
  );
}

class _LiveSummary extends StatelessWidget {
  final Map<String, Map<String, int>> summary;
  const _LiveSummary({required this.summary});
  @override
  Widget build(BuildContext context) {
    var e = 0, a = 0;
    final rows = <List<String>>[];
    for (final x in summary.entries) {
      final ex = x.value['expected'] ?? 0, ac = x.value['actual'] ?? 0;
      e += ex;
      a += ac;
      rows.add([x.key, '$ex', '$ac', '${ex - ac}']);
    }
    rows.add(['Total', '$e', '$a', '${e - a}']);
    return _ResponsiveTable(
      headers: const ['Case Type', 'Expected', 'Actual', 'Unscanned'],
      rows: rows,
      boldLast: true,
    );
  }
}

class _ResponsiveTable extends StatelessWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final bool boldLast;

  const _ResponsiveTable({
    required this.headers,
    required this.rows,
    this.boldLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                columns: headers
                    .map(
                      (header) => DataColumn(
                        label: Text(
                          header,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    )
                    .toList(),
                rows: List.generate(
                  rows.length,
                  (rowIndex) => DataRow(
                    cells: rows[rowIndex]
                        .map(
                          (value) => DataCell(
                            Text(
                              value,
                              style: boldLast && rowIndex == rows.length - 1
                                  ? const TextStyle(fontWeight: FontWeight.bold)
                                  : null,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ContinuousBoxScanner extends StatefulWidget {
  final Future<BoxScanResult> Function(String) onCode;
  const ContinuousBoxScanner({super.key, required this.onCode});
  @override
  State<ContinuousBoxScanner> createState() => _ContinuousBoxScannerState();
}

class _ContinuousBoxScannerState extends State<ContinuousBoxScanner> {
  final controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool busy = false;
  BoxScanResult? last;
  Future<void> detect(BarcodeCapture x) async {
    if (busy || x.barcodes.isEmpty) return;
    final code = x.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    busy = true;
    final result = await widget.onCode(code.toUpperCase());
    if (mounted) setState(() => last = result);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    busy = false;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('CONTINUOUS BOX SCAN')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: controller, onDetect: detect),
        if (last != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: last!.color.withValues(alpha: .94),
              padding: const EdgeInsets.all(20),
              child: Text(
                '${last!.title}\n${last!.initial ?? ''}\n${last!.barcode}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class SingleBoxScanner extends StatefulWidget {
  const SingleBoxScanner({super.key});
  @override
  State<SingleBoxScanner> createState() => _SingleBoxScannerState();
}

class _SingleBoxScannerState extends State<SingleBoxScanner> {
  bool handled = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('SCAN BOX')),
    body: MobileScanner(
      onDetect: (x) {
        if (handled || x.barcodes.isEmpty) return;
        final code = x.barcodes.first.rawValue?.trim();
        if (code == null || code.isEmpty) return;
        handled = true;
        Navigator.pop(context, code.toUpperCase());
      },
    ),
  );
}

class UnscannedScreen extends StatefulWidget {
  final BoxSession session;
  const UnscannedScreen({super.key, required this.session});
  @override
  State<UnscannedScreen> createState() => _UnscannedScreenState();
}

class _UnscannedScreenState extends State<UnscannedScreen> {
  String search = '';
  String? initial;
  Future<List<ExpectedBox>> load() => BoxDb.instance.expected(
    widget.session.id,
    search: search,
    initial: initial,
    unscannedOnly: true,
  );
  Future<void> exportRows(List<ExpectedBox> rows) async {
    final excel = Excel.createExcel();
    excel.rename(excel.getDefaultSheet()!, 'UNSCANNED_BOXES');
    final sheet = excel['UNSCANNED_BOXES'];
    sheet.appendRow([TextCellValue('INITIAL'), TextCellValue('SCONTAINER')]);
    for (final r in rows) {
      sheet.appendRow([TextCellValue(r.initial), TextCellValue(r.scontainer)]);
    }
    final bytes = excel.encode();
    if (bytes != null) {
      await downloadBytes(
        fileName:
            'Unscanned_${widget.session.name.replaceAll(' ', '-')}_${widget.session.date}.xlsx',
        bytes: Uint8List.fromList(bytes),
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('UNSCANNED BOXES')),
    body: FutureBuilder<List<ExpectedBox>>(
      future: load(),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <ExpectedBox>[];
        final types = rows.map((e) => e.initial).toSet().toList()..sort();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: 360,
                    child: TextField(
                      onChanged: (v) => setState(() => search = v),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search SCONTAINER',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  DropdownButton<String>(
                    value: initial,
                    hint: const Text('All Case Types'),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('All Case Types'),
                      ),
                      ...types.map(
                        (e) => DropdownMenuItem(value: e, child: Text(e)),
                      ),
                    ],
                    onChanged: (v) => setState(() => initial = v),
                  ),
                  OutlinedButton.icon(
                    onPressed: rows.isEmpty ? null : () => exportRows(rows),
                    icon: const Icon(Icons.download),
                    label: const Text('EXPORT UNSCANNED'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: snapshot.connectionState != ConnectionState.done
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) => ListTile(
                        leading: CircleAvatar(child: Text(rows[i].initial)),
                        title: Text(rows[i].scontainer),
                      ),
                    ),
            ),
          ],
        );
      },
    ),
  );
}

class BoxHistory extends StatefulWidget {
  const BoxHistory({super.key});
  @override
  State<BoxHistory> createState() => _BoxHistoryState();
}

class _BoxHistoryState extends State<BoxHistory> {
  String query = '';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BOX COUNT HISTORY')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            onChanged: (v) => setState(() => query = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search session, date, status, file, or box barcode',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<BoxSession>>(
            future: BoxDb.instance.sessions(query),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final sessions = snapshot.data ?? const <BoxSession>[];
              if (sessions.isEmpty) {
                return const Center(
                  child: Text('No matching Box Count sessions.'),
                );
              }
              return ListView.builder(
                itemCount: sessions.length,
                itemBuilder: (context, i) =>
                    BoxHistoryCard(session: sessions[i]),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class BoxHistoryCard extends StatelessWidget {
  final BoxSession session;
  const BoxHistoryCard({super.key, required this.session});
  Future<void> export() async {
    final records = await BoxDb.instance.records(session.id),
        sum = await BoxDb.instance.summary(session.id),
        unscanned = await BoxDb.instance.expected(
          session.id,
          unscannedOnly: true,
        ),
        invalid = await BoxDb.instance.attemptCount(session.id, 'INVALID'),
        dup = await BoxDb.instance.attemptCount(session.id, 'DUPLICATE');
    final excel = Excel.createExcel();
    excel.rename(excel.getDefaultSheet()!, 'BOX_SUMMARY');
    final summary = excel['BOX_SUMMARY'];
    summary.appendRow([
      TextCellValue('Case Type'),
      TextCellValue('Expected'),
      TextCellValue('Actual Scanned'),
      TextCellValue('Unscanned'),
    ]);
    var te = 0, ta = 0;
    for (final e in sum.entries) {
      final ex = e.value['expected'] ?? 0, ac = e.value['actual'] ?? 0;
      te += ex;
      ta += ac;
      summary.appendRow([
        TextCellValue(e.key),
        IntCellValue(ex),
        IntCellValue(ac),
        IntCellValue(ex - ac),
      ]);
    }
    summary.appendRow([
      TextCellValue('Total'),
      IntCellValue(te),
      IntCellValue(ta),
      IntCellValue(te - ta),
    ]);
    summary.appendRow([
      TextCellValue('Uploaded File'),
      TextCellValue(session.fileName ?? ''),
    ]);
    summary.appendRow([TextCellValue('Duplicate Attempts'), IntCellValue(dup)]);
    summary.appendRow([
      TextCellValue('Invalid Attempts'),
      IntCellValue(invalid),
    ]);
    final details = excel['BOX_DETAILS'];
    details.appendRow([
      TextCellValue('Box Number'),
      TextCellValue('INITIAL'),
      TextCellValue('SCONTAINER'),
      TextCellValue('Scan Date'),
      TextCellValue('Scan Time'),
    ]);
    for (var i = 0; i < records.reversed.length; i++) {
      final r = records.reversed.elementAt(i);
      details.appendRow([
        IntCellValue(i + 1),
        TextCellValue(r.initial),
        TextCellValue(r.barcode),
        TextCellValue(r.date),
        TextCellValue(r.time),
      ]);
    }
    final missing = excel['UNSCANNED_BOXES'];
    missing.appendRow([TextCellValue('INITIAL'), TextCellValue('SCONTAINER')]);
    for (final r in unscanned) {
      missing.appendRow([
        TextCellValue(r.initial),
        TextCellValue(r.scontainer),
      ]);
    }
    final bytes = excel.encode();
    if (bytes != null) {
      await downloadBytes(
        fileName:
            'BoxCount_${session.name.replaceAll(' ', '-')}_${session.date}.xlsx',
        bytes: Uint8List.fromList(bytes),
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<Map<String, Map<String, int>>>(
    future: BoxDb.instance.summary(session.id),
    builder: (context, snapshot) {
      final sum = snapshot.data ?? {};
      final expected = sum.values.fold(0, (a, e) => a + (e['expected'] ?? 0)),
          actual = sum.values.fold(0, (a, e) => a + (e['actual'] ?? 0)),
          missing = expected - actual;
      return Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      session.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Chip(label: Text(session.status)),
                ],
              ),
              Text('${session.date} ${session.startTime}'),
              if (session.fileName != null)
                Text('Box List: ${session.fileName}'),
              Text('Expected: $expected'),
              Text('Actual Scanned: $actual'),
              Text('Unscanned: $missing'),
              Text(
                'Completion: ${expected == 0 ? 0 : (actual / expected * 100).round()}%',
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () async {
                  if (session.status == 'DRAFT') {
                    await BoxDb.instance.startSavedSession(session.id);
                  } else if (session.status != 'ACTIVE') {
                    await BoxDb.instance.reopen(session.id);
                  }
                  if (context.mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            BoxCountScreen(session: session.activeCopy()),
                      ),
                    );
                  }
                },
                child: Text(
                  session.status == 'ACTIVE'
                      ? 'CONTINUE SCANNING'
                      : session.status == 'DRAFT'
                      ? 'START SCANNING'
                      : 'REOPEN & CONTINUE',
                ),
              ),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => UnscannedScreen(session: session),
                  ),
                ),
                child: const Text('VIEW UNSCANNED BOXES'),
              ),
              OutlinedButton(
                onPressed: export,
                child: const Text('DOWNLOAD EXCEL'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
