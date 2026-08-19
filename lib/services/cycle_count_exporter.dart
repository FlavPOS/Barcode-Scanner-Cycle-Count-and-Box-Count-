import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../platform/file_download.dart';
import 'cycle_count_database.dart';

class CycleCountExporter {
  static Future<String> exportSession(CycleSession session) async {
    final records = await CycleCountDatabase.instance.records(session.id);
    final workbook = Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet();

    if (defaultSheet != null) {
      workbook.rename(defaultSheet, 'BARCODE_SUMMARY');
    }

    final summary = workbook['BARCODE_SUMMARY'];

    // Group every separately saved scan by barcode.
    final grouped = <String, List<CycleRecord>>{};
    for (final record in records.reversed) {
      grouped.putIfAbsent(record.barcode, () => <CycleRecord>[]).add(record);
    }

    var maximumScans = 0;
    for (final scans in grouped.values) {
      if (scans.length > maximumScans) maximumScans = scans.length;
    }

    final summaryHeader = <CellValue>[
      TextCellValue('Session ID'),
      TextCellValue('Session Name'),
      TextCellValue('Scan Number'),
      TextCellValue('Date'),
      TextCellValue('Barcode'),
      TextCellValue('Total Scanned'),
    ];

    for (var scanIndex = 1; scanIndex <= maximumScans; scanIndex++) {
      summaryHeader.add(TextCellValue('Qty Scanned $scanIndex'));
    }
    summary.appendRow(summaryHeader);

    var summaryRowNumber = 1;
    for (final entry in grouped.entries) {
      final scans = entry.value;
      final totalQuantity = scans.fold<int>(0, (sum, scan) => sum + scan.qty);
      final summaryRow = <CellValue>[
        TextCellValue(session.id),
        TextCellValue(session.name),
        IntCellValue(summaryRowNumber),
        TextCellValue(session.date),
        TextCellValue(entry.key),
        IntCellValue(totalQuantity),
      ];

      for (final scan in scans) {
        summaryRow.add(IntCellValue(scan.qty));
      }
      while (summaryRow.length < summaryHeader.length) {
        summaryRow.add(TextCellValue(''));
      }
      summary.appendRow(summaryRow);
      summaryRowNumber++;
    }

    // Keep full audit details as a separate worksheet.
    final details = workbook['SCAN_DETAILS'];
    details.appendRow([
      TextCellValue('Session ID'),
      TextCellValue('Session Name'),
      TextCellValue('Scan Number'),
      TextCellValue('Date'),
      TextCellValue('Time'),
      TextCellValue('Barcode'),
      TextCellValue('Qty Scanned'),
    ]);

    for (var index = 0; index < records.reversed.length; index++) {
      final row = records.reversed.elementAt(index);
      details.appendRow([
        TextCellValue(session.id),
        TextCellValue(session.name),
        IntCellValue(index + 1),
        TextCellValue(row.date),
        TextCellValue(row.time),
        TextCellValue(row.barcode),
        IntCellValue(row.qty),
      ]);
    }

    final encoded = workbook.encode();
    if (encoded == null) {
      throw StateError('Unable to generate Excel file.');
    }

    final safeName = session.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
    final fileName = 'CycleCount_${safeName}_${session.date}.xlsx';

    return downloadBytes(
      fileName: fileName,
      bytes: Uint8List.fromList(encoded),
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }
}
