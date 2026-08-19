import 'dart:async';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';

import '../platform/database_platform.dart';
import '../platform/file_download.dart';

class BoxSession {
  final String id, name, date, startTime, status;
  final String? endTime;
  final bool continuous;
  const BoxSession({
    required this.id,
    required this.name,
    required this.date,
    required this.startTime,
    required this.status,
    required this.continuous,
    this.endTime,
  });
  factory BoxSession.fromMap(Map<String, Object?> m) => BoxSession(
    id: m['id'] as String,
    name: m['name'] as String,
    date: m['date'] as String,
    startTime: m['start_time'] as String,
    status: m['status'] as String,
    continuous: (m['continuous'] as int) == 1,
    endTime: m['end_time'] as String?,
  );
}

class BoxRecord {
  final int id;
  final String sessionId, barcode, date, time;
  const BoxRecord(this.id, this.sessionId, this.barcode, this.date, this.time);
  factory BoxRecord.fromMap(Map<String, Object?> m) => BoxRecord(
    m['id'] as int,
    m['session_id'] as String,
    m['barcode'] as String,
    m['scan_date'] as String,
    m['scan_time'] as String,
  );
}

class BoxDb {
  BoxDb._();
  static final instance = BoxDb._();
  Database? _db;
  String two(int n) => n.toString().padLeft(2, '0');
  String d(DateTime n) => '${n.year}-${two(n.month)}-${two(n.day)}';
  String t(DateTime n) => '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  Future<Database> get db async {
    if (_db != null) return _db!;
    final path = await resolveDatabasePath();
    _db = await databaseFactory.openDatabase(
      '${path}_boxes',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) async {
          await db.execute(
            'CREATE TABLE box_sessions(id TEXT PRIMARY KEY,name TEXT NOT NULL,date TEXT NOT NULL,start_time TEXT NOT NULL,end_time TEXT,status TEXT NOT NULL,continuous INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE box_records(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,barcode TEXT NOT NULL,scan_date TEXT NOT NULL,scan_time TEXT NOT NULL,UNIQUE(session_id,barcode))',
          );
          await db.execute(
            'CREATE TABLE box_duplicates(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,barcode TEXT NOT NULL,attempt_date TEXT NOT NULL,attempt_time TEXT NOT NULL)',
          );
        },
      ),
    );
    return _db!;
  }

  Future<BoxSession> create(String name, bool continuous) async {
    final x = DateTime.now(),
        s = BoxSession(
          id: 'BC${x.millisecondsSinceEpoch}',
          name: name,
          date: d(x),
          startTime: t(x),
          status: 'ACTIVE',
          continuous: continuous,
        );
    final z = await db;
    await z.update(
      'box_sessions',
      {'status': 'FINISHED'},
      where: 'status=?',
      whereArgs: ['ACTIVE'],
    );
    await z.insert('box_sessions', {
      'id': s.id,
      'name': s.name,
      'date': s.date,
      'start_time': s.startTime,
      'end_time': null,
      'status': s.status,
      'continuous': continuous ? 1 : 0,
    });
    return s;
  }

  Future<List<BoxSession>> sessions([String q = '']) async {
    final z = await db, p = '%${q.trim()}%';
    final rows = q.trim().isEmpty
        ? await z.query('box_sessions', orderBy: 'date DESC,start_time DESC')
        : await z.rawQuery(
            'SELECT DISTINCT s.* FROM box_sessions s LEFT JOIN box_records r ON r.session_id=s.id LEFT JOIN box_duplicates d ON d.session_id=s.id WHERE s.id LIKE ? OR s.name LIKE ? OR s.date LIKE ? OR s.status LIKE ? OR r.barcode LIKE ? OR d.barcode LIKE ? ORDER BY s.date DESC,s.start_time DESC',
            [p, p, p, p, p, p],
          );
    return rows.map(BoxSession.fromMap).toList();
  }

  Future<List<BoxRecord>> records(String id) async => (await (await db).query(
    'box_records',
    where: 'session_id=?',
    whereArgs: [id],
    orderBy: 'id DESC',
  )).map(BoxRecord.fromMap).toList();
  Future<int> duplicates(String id) async =>
      Sqflite.firstIntValue(
        await (await db).rawQuery(
          'SELECT COUNT(*) FROM box_duplicates WHERE session_id=?',
          [id],
        ),
      ) ??
      0;
  Future<bool> scan(String id, String code) async {
    final z = await db, x = DateTime.now();
    try {
      await z.insert('box_records', {
        'session_id': id,
        'barcode': code,
        'scan_date': d(x),
        'scan_time': t(x),
      });
      return true;
    } catch (_) {
      await z.insert('box_duplicates', {
        'session_id': id,
        'barcode': code,
        'attempt_date': d(x),
        'attempt_time': t(x),
      });
      return false;
    }
  }

  Future<void> finish(String id) async {
    final x = DateTime.now();
    await (await db).update(
      'box_sessions',
      {'status': 'FINISHED', 'end_time': t(x)},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> reopen(String id) async {
    final z = await db;
    await z.update(
      'box_sessions',
      {'status': 'FINISHED'},
      where: 'status=? AND id!=?',
      whereArgs: ['ACTIVE', id],
    );
    await z.update(
      'box_sessions',
      {'status': 'ACTIVE', 'end_time': null},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> remove(int id) async =>
      (await db).delete('box_records', where: 'id=?', whereArgs: [id]);
}

class BoxCountHome extends StatefulWidget {
  const BoxCountHome({super.key});
  @override
  State<BoxCountHome> createState() => _BoxCountHomeState();
}

class _BoxCountHomeState extends State<BoxCountHome> {
  Future<void> start() async {
    String name = '';
    bool continuous = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('START BOX COUNT'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onChanged: (v) => name = v,
                decoration: const InputDecoration(labelText: 'Session Name'),
              ),
              SwitchListTile(
                value: continuous,
                onChanged: (v) => set(() => continuous = v),
                title: const Text('Continuous Scanning'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('START'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || name.trim().isEmpty || !mounted) return;
    final s = await BoxDb.instance.create(name.trim(), continuous);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BoxCountScreen(session: s)),
      );
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('BOX COUNT')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: start,
            icon: const Icon(Icons.add_box),
            label: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('START BOX COUNT'),
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              c,
              MaterialPageRoute(builder: (_) => const BoxHistory()),
            ),
            icon: const Icon(Icons.history),
            label: const Padding(
              padding: EdgeInsets.all(14),
              child: Text('BOX COUNT HISTORY'),
            ),
          ),
        ],
      ),
    ),
  );
}

class BoxCountScreen extends StatefulWidget {
  final BoxSession session;
  const BoxCountScreen({super.key, required this.session});
  @override
  State<BoxCountScreen> createState() => _BoxCountScreenState();
}

class _BoxCountScreenState extends State<BoxCountScreen> {
  List<BoxRecord> rows = [];
  int dup = 0;
  bool get continuous => widget.session.continuous;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    rows = await BoxDb.instance.records(widget.session.id);
    dup = await BoxDb.instance.duplicates(widget.session.id);
    if (mounted) setState(() {});
  }

  Future<void> accept(String code) async {
    final valid = await BoxDb.instance.scan(widget.session.id, code);
    await load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: valid ? Colors.green : Colors.red,
          content: Text(valid ? 'BOX SAVED' : 'DUPLICATE BOX'),
        ),
      );
    }
  }

  Future<void> camera() async {
    if (continuous) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ContinuousBoxScanner(onCode: accept)),
      );
      await load();
    } else {
      final code = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const SingleBoxScanner()),
      );
      if (code != null) await accept(code);
    }
  }

  Future<void> manual() async {
    String v = '';
    final x = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('BOX BARCODE'),
        content: TextField(autofocus: true, onChanged: (s) => v = s),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c, v.trim()),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    if (x != null && x.isNotEmpty) await accept(x);
  }

  Future<void> finish() async {
    await BoxDb.instance.finish(widget.session.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: Text(widget.session.name),
      actions: [IconButton(onPressed: finish, icon: const Icon(Icons.done))],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: camera,
      icon: const Icon(Icons.qr_code_scanner),
      label: Text(continuous ? 'CONTINUOUS SCAN' : 'SCAN BOX'),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Valid Boxes\n${rows.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  'Duplicates\n$dup',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(onPressed: manual, icon: const Icon(Icons.keyboard)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (c, i) {
              final r = rows[i];
              return Card(
                child: ListTile(
                  title: Text(r.barcode),
                  subtitle: Text('${r.date} ${r.time}'),
                  trailing: Text('BOX ${rows.length - i}'),
                  onLongPress: () async {
                    final ok = await showDialog<bool>(
                      context: c,
                      builder: (d) => AlertDialog(
                        title: Text(r.barcode),
                        content: const Text('Remove this box?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('CANCEL'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const Text('REMOVE'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await BoxDb.instance.remove(r.id);
                      await load();
                    }
                  },
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class ContinuousBoxScanner extends StatefulWidget {
  final Future<void> Function(String) onCode;
  const ContinuousBoxScanner({super.key, required this.onCode});
  @override
  State<ContinuousBoxScanner> createState() => _ContinuousBoxScannerState();
}

class _ContinuousBoxScannerState extends State<ContinuousBoxScanner> {
  final ctl = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool busy = false;
  String last = '';
  Future<void> detect(BarcodeCapture x) async {
    if (busy || x.barcodes.isEmpty) return;
    final s = x.barcodes.first.rawValue?.trim();
    if (s == null || s.isEmpty) return;
    busy = true;
    await widget.onCode(s);
    if (mounted) setState(() => last = s);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    busy = false;
  }

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('CONTINUOUS BOX SCAN')),
    body: Stack(
      children: [
        MobileScanner(controller: ctl, onDetect: detect),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.all(18),
            width: double.infinity,
            child: Text(
              last.isEmpty ? 'Scan a box label' : 'Last: $last',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    ),
  );
}

class SingleBoxScanner extends StatelessWidget {
  const SingleBoxScanner({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('SCAN BOX')),
    body: MobileScanner(
      onDetect: (x) {
        final s = x.barcodes.firstOrNull?.rawValue?.trim();
        if (s != null && s.isNotEmpty) Navigator.pop(c, s);
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
  String q = '';
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('BOX COUNT HISTORY')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search session, date, status, or box barcode',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<BoxSession>>(
            future: BoxDb.instance.sessions(q),
            builder: (c, s) {
              if (!s.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return ListView.builder(
                itemCount: s.data!.length,
                itemBuilder: (c, i) => BoxHistoryCard(
                  session: s.data![i],
                  refresh: () => setState(() {}),
                ),
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
  final VoidCallback refresh;
  const BoxHistoryCard({
    super.key,
    required this.session,
    required this.refresh,
  });
  Future<void> export() async {
    final records = await BoxDb.instance.records(session.id),
        dups = await BoxDb.instance.duplicates(session.id),
        x = Excel.createExcel();
    x.rename(x.getDefaultSheet()!, 'BOX_SUMMARY');
    x['BOX_SUMMARY'].appendRow([
      TextCellValue('Session ID'),
      TextCellValue('Session Name'),
      TextCellValue('Date'),
      TextCellValue('Status'),
      TextCellValue('Continuous Scanning'),
      TextCellValue('Valid Boxes'),
      TextCellValue('Duplicate Attempts'),
    ]);
    x['BOX_SUMMARY'].appendRow([
      TextCellValue(session.id),
      TextCellValue(session.name),
      TextCellValue(session.date),
      TextCellValue(session.status),
      TextCellValue(session.continuous ? 'ON' : 'OFF'),
      IntCellValue(records.length),
      IntCellValue(dups),
    ]);
    final d = x['BOX_DETAILS'];
    d.appendRow([
      TextCellValue('Box Number'),
      TextCellValue('Scan Date'),
      TextCellValue('Scan Time'),
      TextCellValue('Box Barcode'),
    ]);
    for (var i = 0; i < records.reversed.length; i++) {
      final r = records.reversed.elementAt(i);
      d.appendRow([
        IntCellValue(i + 1),
        TextCellValue(r.date),
        TextCellValue(r.time),
        TextCellValue(r.barcode),
      ]);
    }
    final b = x.encode();
    if (b != null) {
      await downloadBytes(
        fileName:
            'BoxCount_${session.name.replaceAll(' ', '-')}_${session.date}.xlsx',
        bytes: Uint8List.fromList(b),
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    }
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<List<BoxRecord>>(
    future: BoxDb.instance.records(session.id),
    builder: (c, r) => Card(
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
            Text('Valid Boxes: ${r.data?.length ?? 0}'),
            Text('Continuous Scanning: ${session.continuous ? 'ON' : 'OFF'}'),
            FilledButton(
              onPressed: () async {
                if (session.status != 'ACTIVE') {
                  await BoxDb.instance.reopen(session.id);
                }
                if (c.mounted) {
                  Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => BoxCountScreen(
                        session: BoxSession(
                          id: session.id,
                          name: session.name,
                          date: session.date,
                          startTime: session.startTime,
                          status: 'ACTIVE',
                          continuous: session.continuous,
                        ),
                      ),
                    ),
                  );
                }
              },
              child: Text(
                session.status == 'ACTIVE'
                    ? 'CONTINUE SCANNING'
                    : 'REOPEN & CONTINUE',
              ),
            ),
            OutlinedButton(
              onPressed: export,
              child: const Text('DOWNLOAD EXCEL'),
            ),
          ],
        ),
      ),
    ),
  );
}
