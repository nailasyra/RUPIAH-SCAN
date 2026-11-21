
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

class OnnxService {
  OrtSession? _session;
  OrtRunOptions? _runOptions;

  // URUTAN HARUS SAMA PERSIS dengan class_names di Colab (alfabetis).
  // Cek dengan: print(class_names) atau lihat labels.txt / config.json
  static const List<String> labels = [
    'duapuluhribu',
    'duaribu',
    'limapuluhribu',
    'limaribu',
    'other',
    'sepuluhribu',
    'seratusribu',
    'seribu',
  ];

  static const String otherLabel = 'other';

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
          throw Exception('Output model bukan ${labels.length} kelas');
        }

        var bestIndex = 0;

        for (var i = 1; i < scores.length; i++) {
          if (scores[i] > scores[bestIndex]) {
            bestIndex = i;
          }
        }

        // tebakan kedua, untuk menghitung selisih (margin)
        var secondIndex = bestIndex == 0 ? 1 : 0;

        for (var i = 0; i < scores.length; i++) {
          if (i != bestIndex && scores[i] > scores[secondIndex]) {
            secondIndex = i;
          }
        }

        final confidence = scores[bestIndex];
        final margin = confidence - scores[secondIndex];
        final label = labels[bestIndex];

        return {
          'label': label,
          'confidence': confidence,
          'margin': margin,
          'status': decide(label, confidence, margin),
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

  // Samakan dengan T_ACCEPT dan MARGIN di Colab (lihat config.json)
  static const double tAccept = 0.7;
  static const double marginMin = 0.2;

  /// 'money' | 'not_money' | 'unsure'
  static String decide(String label, double confidence, double margin) {
    if (label == otherLabel && confidence >= 0.5) {
      return 'not_money';
    }

    if (label != otherLabel && confidence >= tAccept && margin >= marginMin) {
      return 'money';
    }

    return 'unsure';
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
