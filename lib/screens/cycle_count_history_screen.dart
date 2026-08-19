import 'package:flutter/material.dart';

import '../services/cycle_count_database.dart';
import '../services/cycle_count_exporter.dart';

class CycleCountHistoryScreen extends StatefulWidget {
  const CycleCountHistoryScreen({super.key});

  @override
  State<CycleCountHistoryScreen> createState() =>
      _CycleCountHistoryScreenState();
}

class _CycleCountHistoryScreenState extends State<CycleCountHistoryScreen> {
  late Future<List<CycleSession>> _sessionsFuture;
  String? _exportingSessionId;

  @override
  void initState() {
    super.initState();
    _sessionsFuture = CycleCountDatabase.instance.allSessions();
  }

  Future<void> _export(CycleSession session) async {
    setState(() => _exportingSessionId = session.id);
    try {
      final result = await CycleCountExporter.exportSession(session);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Excel ready: $result')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) setState(() => _exportingSessionId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CYCLE COUNT HISTORY')),
      body: FutureBuilder<List<CycleSession>>(
        future: _sessionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Unable to load history: ${snapshot.error}'),
            );
          }
          final sessions = snapshot.data ?? const <CycleSession>[];
          if (sessions.isEmpty) {
            return const Center(child: Text('No Cycle Count sessions yet.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final session = sessions[index];
              return FutureBuilder<Map<String, int>>(
                future: CycleCountDatabase.instance.sessionTotals(session.id),
                builder: (context, totalsSnapshot) {
                  final totals =
                      totalsSnapshot.data ??
                      const {'scan_count': 0, 'total_qty': 0};
                  final exporting = _exportingSessionId == session.id;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                          Text('${session.date}  ${session.startTime}'),
                          if (session.endTime != null)
                            Text('Ended: ${session.endTime}'),
                          const SizedBox(height: 12),
                          Text('Total Scans: ${totals['scan_count']}'),
                          Text('Total Qty: ${totals['total_qty']}'),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: exporting
                                  ? null
                                  : () => _export(session),
                              icon: exporting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.download),
                              label: Text(
                                exporting ? 'GENERATING...' : 'DOWNLOAD EXCEL',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
