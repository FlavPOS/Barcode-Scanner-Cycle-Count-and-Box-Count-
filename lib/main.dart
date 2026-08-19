import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'platform/database_platform.dart';
import 'screens/cycle_count_history_screen.dart';
import 'services/cycle_count_database.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureDatabasePlatform();
  runApp(const ScannerApp());
}

void disposeTextControllerAfterFrame(TextEditingController controller) {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    controller.dispose();
  });
}

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scanner App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B5CEB)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
      ),
      home: const CycleCountHome(),
    );
  }
}

class CycleCountHome extends StatefulWidget {
  const CycleCountHome({super.key});

  @override
  State<CycleCountHome> createState() => _CycleCountHomeState();
}

class _CycleCountHomeState extends State<CycleCountHome> {
  CycleSession? _active;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = await CycleCountDatabase.instance.getActiveSession();
    if (!mounted) return;
    setState(() {
      _active = session;
      _loading = false;
    });
  }

  Future<void> _createSession() async {
    final controller = TextEditingController(
      text: '${DateTime.now().month}/${DateTime.now().day} Cycle Count',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cycle Count Session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Session Name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('START'),
          ),
        ],
      ),
    );
    disposeTextControllerAfterFrame(controller);
    if (name == null) return;
    final session = await CycleCountDatabase.instance.createSession(
      name,
      DateTime.now(),
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CycleCountScreen(session: session)),
    );
    await _load();
  }

  Future<void> _continueSession() async {
    final session = _active;
    if (session == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CycleCountScreen(session: session)),
    );
    await _load();
  }

  Future<void> _openHistory() async {
    final selectedSession = await Navigator.push<CycleSession>(
      context,
      MaterialPageRoute(builder: (_) => const CycleCountHistoryScreen()),
    );
    if (selectedSession == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CycleCountScreen(session: selectedSession),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SCANNER APP')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.inventory_2_outlined,
                    size: 76,
                    color: Color(0xFF5B5CEB),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'CYCLE COUNT',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Offline barcode and quantity recording. No Masterfile.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  if (_active != null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ACTIVE SESSION',
                              style: TextStyle(
                                color: Color(0xFF5B5CEB),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _active!.name,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text('${_active!.date}  ${_active!.startTime}'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _continueSession,
                      icon: const Icon(Icons.play_arrow),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('CONTINUE SESSION'),
                      ),
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: _createSession,
                      icon: const Icon(Icons.add),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('START CYCLE COUNT'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _openHistory,
                    icon: const Icon(Icons.history),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('CYCLE COUNT HISTORY'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class CycleCountScreen extends StatefulWidget {
  const CycleCountScreen({super.key, required this.session});
  final CycleSession session;

  @override
  State<CycleCountScreen> createState() => _CycleCountScreenState();
}

class _CycleCountScreenState extends State<CycleCountScreen> {
  List<CycleRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    final records = await CycleCountDatabase.instance.records(
      widget.session.id,
    );
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _scan() async {
    final barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
    );
    if (barcode == null || !mounted) return;
    await _captureQuantity(barcode);
  }

  Future<void> _manualBarcode() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Barcode'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Barcode',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('NEXT'),
          ),
        ],
      ),
    );
    disposeTextControllerAfterFrame(controller);
    if (value != null && value.isNotEmpty) await _captureQuantity(value);
  }

  Future<void> _captureQuantity(String barcode) async {
    final previous = _records.where((row) => row.barcode == barcode).toList();
    final previousTotal = previous.fold<int>(0, (sum, row) => sum + row.qty);
    final qtyController = TextEditingController();

    final qty = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(previous.isEmpty ? 'COUNTED QTY' : 'SAVE ANOTHER SCAN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('BARCODE'),
            const SizedBox(height: 5),
            SelectableText(
              barcode,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            if (previous.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Previous Scans: ${previous.length}'),
              Text('Previous Total Qty: $previousTotal'),
              const Text('The new quantity will be saved separately.'),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: qtyController,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                labelText: 'Qty for This Scan',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submitQty(context, qtyController),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => _submitQty(context, qtyController),
            child: const Text('SAVE NEW SCAN'),
          ),
        ],
      ),
    );
    qtyController.dispose();
    if (qty == null) return;

    await CycleCountDatabase.instance.insertRecord(
      sessionId: widget.session.id,
      barcode: barcode,
      qty: qty,
      now: DateTime.now(),
    );
    await _loadRecords();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$barcode saved as Scan ${previous.length + 1} with Qty $qty',
        ),
      ),
    );
  }

  void _submitQty(
    BuildContext dialogContext,
    TextEditingController controller,
  ) {
    final qty = int.tryParse(controller.text.trim());
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(content: Text('Enter a quantity greater than zero.')),
      );
      return;
    }
    Navigator.pop(dialogContext, qty);
  }

  Future<void> _finish() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish Cycle Count?'),
        content: const Text('The session will be marked as finished.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('FINISH'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await CycleCountDatabase.instance.finishSession(
      widget.session.id,
      DateTime.now(),
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final totalQty = _records.fold<int>(0, (sum, row) => sum + row.qty);
    return Scaffold(
      appBar: AppBar(
        title: const Text('CYCLE COUNT'),
        actions: [TextButton(onPressed: _finish, child: const Text('FINISH'))],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF5B5CEB),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  widget.session.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _Metric(label: 'Total Scans', value: '${_records.length}'),
                    _Metric(label: 'Total Qty', value: '$totalQty'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                ? const Center(child: Text('No records. Scan a barcode.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                    itemCount: _records.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final row = _records[index];
                      return Card(
                        color: Colors.white,
                        child: ListTile(
                          leading: const Icon(Icons.qr_code_2),
                          title: Text(
                            row.barcode,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text('${row.date}  ${row.time}'),
                          trailing: Text(
                            '${row.qty}',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF5B5CEB),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'manual',
            onPressed: _manualBarcode,
            child: const Icon(Icons.keyboard),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'scan',
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('SCAN BARCODE'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.itf14,
      BarcodeFormat.qrCode,
    ],
  );
  bool _handled = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue?.trim();
    if (value == null || value.isEmpty) return;
    _handled = true;
    await _controller.stop();
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(value);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('SCAN BARCODE'),
        actions: [
          IconButton(
            onPressed: _controller.toggleTorch,
            icon: const Icon(Icons.flash_on),
          ),
          IconButton(
            onPressed: _controller.switchCamera,
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 300,
              height: 170,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.greenAccent, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Text(
                'Place the barcode inside the frame',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
