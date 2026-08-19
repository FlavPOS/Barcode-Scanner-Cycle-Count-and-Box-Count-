import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../platform/file_download.dart';
import 'cycle_count_database.dart';

class CycleCountExporter {
  static Future<String> exportSession(CycleSession session) async {
    final records = await CycleCountDatabase.instance.records(session.id);
    final workbook = Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet();
    if (defaultSheet != null) workbook.rename(defaultSheet, 'SCAN_DETAILS');

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

    for (var index = 0; index < records.length; index++) {
      final row = records[index];
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

    final summaryRows = await CycleCountDatabase.instance.barcodeSummary(
      session.id,
    );
    final summary = workbook['UPC_SUMMARY'];
    summary.appendRow([
      TextCellValue('Session ID'),
      TextCellValue('Session Name'),
      TextCellValue('Barcode'),
      TextCellValue('Number of Scans'),
      TextCellValue('Total Qty Scanned'),
    ]);
    for (final row in summaryRows) {
      summary.appendRow([
        TextCellValue(session.id),
        TextCellValue(session.name),
        TextCellValue(row['barcode'] as String),
        IntCellValue((row['scan_count'] as num).toInt()),
        IntCellValue((row['total_qty'] as num).toInt()),
      ]);
    }

    final encoded = workbook.encode();
    if (encoded == null) throw StateError('Unable to generate Excel file.');
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
