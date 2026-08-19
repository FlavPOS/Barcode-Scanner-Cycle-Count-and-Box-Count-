import 'dart:async';

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
  final TextEditingController _searchController = TextEditingController();
  late Future<List<CycleSession>> _sessionsFuture;
  Timer? _searchDebounce;
  String? _exportingSessionId;
  String? _reopeningSessionId;

  @override
  void initState() {
    super.initState();
    _sessionsFuture = CycleCountDatabase.instance.allSessions();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _search(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _sessionsFuture = CycleCountDatabase.instance.searchSessions(value);
      });
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _sessionsFuture = CycleCountDatabase.instance.allSessions();
    });
  }

  Future<void> _reopen(CycleSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reopen Cycle Count?'),
        content: Text(
          'Reopen "${session.name}" and continue adding separate barcode scans?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('REOPEN & CONTINUE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _reopeningSessionId = session.id);
    await CycleCountDatabase.instance.reopenSession(session.id);
    if (!mounted) return;

    final reopened = CycleSession(
      id: session.id,
      name: session.name,
      date: session.date,
      startTime: session.startTime,
      endTime: null,
      status: 'ACTIVE',
    );
    Navigator.pop(context, reopened);
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: 'Search session, date, status, or barcode',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.clear),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<CycleSession>>(
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
                  return const Center(
                    child: Text('No matching Cycle Count sessions.'),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    return FutureBuilder<Map<String, int>>(
                      future: CycleCountDatabase.instance.sessionTotals(
                        session.id,
                      ),
                      builder: (context, totalsSnapshot) {
                        final totals =
                            totalsSnapshot.data ??
                            const {'scan_count': 0, 'total_qty': 0};
                        final exporting = _exportingSessionId == session.id;
                        final reopening = _reopeningSessionId == session.id;
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
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: reopening
                                        ? null
                                        : () => _reopen(session),
                                    icon: reopening
                                        ? const SizedBox.square(
                                            dimension: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.play_arrow),
                                    label: Text(
                                      session.status == 'ACTIVE'
                                          ? 'CONTINUE SCANNING'
                                          : 'REOPEN & CONTINUE',
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
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
                                      exporting
                                          ? 'GENERATING...'
                                          : 'DOWNLOAD EXCEL',
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
          ),
        ],
      ),
    );
  }
}
