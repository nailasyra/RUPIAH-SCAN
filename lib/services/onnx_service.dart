
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

class OnnxService {
  OrtSession? _session;
  OrtRunOptions? _runOptions;

  static const List<String> labels = [
    'duak',
    'duapuluhk',
    'limak',
    'limapuluhk',
    'sepuluhk',
    'seratusk',
    'seribuk',
  ];

  Future<void> initialize() async {
    try {
      OrtEnv.instance.init();

      final modelData =
          await rootBundle.load('assets/models/MobilE-UANG.onnx');

      final modelBytes = modelData.buffer.asUint8List(
        modelData.offsetInBytes,
        modelData.lengthInBytes,
      );

      final sessionOptions = OrtSessionOptions();

      _session = OrtSession.fromBuffer(
        modelBytes,
        sessionOptions,
      );

      sessionOptions.release();

      _runOptions = OrtRunOptions();

      print('Model ONNX berhasil dimuat!');
      print('Input: ${_session!.inputNames}');
      print('Output: ${_session!.outputNames}');
    } catch (e) {
      print('Gagal memuat model ONNX: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> predict(Float32List inputData) async {
    if (_session == null || _runOptions == null) {
      throw Exception('Model ONNX belum diinisialisasi');
    }

    if (inputData.length != 224 * 224 * 3) {
      throw Exception('Ukuran input harus 224 x 224 x 3');
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      inputData,
      [1, 224, 224, 3],
    );

    try {
      final outputs = _session!.run(
        _runOptions!,
        {
          _session!.inputNames.first: inputTensor,
        },
      );

      try {
        final outputTensor = outputs.first as OrtValueTensor;
        final scores = _flatten(outputTensor.value);

        if (scores.length != labels.length) {
          throw Exception('Output model bukan 7 kelas');
        }

        var bestIndex = 0;

        for (var i = 1; i < scores.length; i++) {
          if (scores[i] > scores[bestIndex]) {
            bestIndex = i;
          }
        }

        return {
          'label': labels[bestIndex],
          'confidence': scores[bestIndex],
          'scores': scores,
        };
      } finally {
        for (final output in outputs) {
          output?.release();
        }
      }
    } finally {
      inputTensor.release();
    }
  }

  List<double> _flatten(dynamic value) {
    if (value is num) {
      return [value.toDouble()];
    }

    if (value is List) {
      return value.expand((item) => _flatten(item)).toList();
    }

    throw Exception('Format output model tidak dikenali');
  }

  void dispose() {
    _runOptions?.release();
    _runOptions = null;

    _session?.release();
    _session = null;
  }
}
