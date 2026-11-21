import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/onnx_service.dart';
import '../services/audio_service.dart';
import '../utils/image_preprocessing.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  // ==============================
  // PENGATURAN
  // ==============================

  bool voiceEnabled = true;
  double audioSpeed = 1.0;

  final Color purple = const Color(0xFF8957E5);
  final Color darkCard = const Color(0xFF24232D);

  // ==============================
  // KAMERA
  // ==============================

  CameraController? cameraController;
  bool isCameraInitialized = false;
  String cameraError = '';

  // ==============================
  // SERVICE
  // ==============================

  final OnnxService onnxService = OnnxService();
  final AudioService audioService = AudioService();
  final FlutterTts flutterTts = FlutterTts();

  bool isModelInitialized = false;
  bool isTtsReady = false;
  bool isSpeaking = false;
  bool isCandidateDetected = false;
  bool isShowingResult = false;
  int secondsWithoutMoney = 0;
  Timer? guidanceTimer;

  // ==============================
  // AUTO SCAN
  // ==============================

  Timer? scanTimer;

  bool isProcessing = false;

  Float32List? previousFrame;

  int stableCount = 0;

  String? lastLabel;

  bool hasAnnounced = false;

  // FREEZE FRAME saat nominal siap diumumkan
  bool isFrozen = false;
  Uint8List? frozenFrameBytes;

  // Jumlah sampel stabil berturut-turut sebelum nominal diumumkan
  static const int requiredStable = 3;

  // Kalimat yang diucapkan guidance timer (berubah sesuai situasi)
  String guidanceMessage = 'Silakan arahkan uang ke kamera.';

  String scanStatus = 'MENYIAPKAN MODEL...';

  String scanMessage = 'Mohon tunggu sebentar.';

  // ==============================
  // INIT STATE
  // ==============================

  @override
  void initState() {
    super.initState();

    initializeCamera();
    initializeModel();
    initializeTts();
  }

  // ==============================
  // INISIALISASI TEXT TO SPEECH
  // ==============================

  Future<void> initializeTts() async {
    try {
      await flutterTts.setLanguage('id-ID');
      await flutterTts.awaitSpeakCompletion(true);
      await flutterTts.setSpeechRate(0.45);
      await flutterTts.setVolume(1.0);
      await flutterTts.setPitch(1.0);

      flutterTts.setStartHandler(() {
        isSpeaking = true;
      });
      flutterTts.setCompletionHandler(() {
        isSpeaking = false;
      });
      flutterTts.setErrorHandler((message) {
        isSpeaking = false;
        debugPrint('TTS error: $message');
      });

      isTtsReady = true;
      if (voiceEnabled) {
        await speakInstruction('RupiahScan siap digunakan.');
      }
    } catch (e) {
      debugPrint('Gagal menyiapkan TTS: $e');
    }
  }

  Future<void> speakInstruction(String text) async {
    if (!voiceEnabled || !isTtsReady || isSpeaking || isShowingResult) {
      return;
    }

    try {
      await flutterTts.speak(text);
    } catch (e) {
      debugPrint('Gagal memutar instruksi TTS: $e');
    }
  }

  Future<void> speakCountdown() async {
    if (!voiceEnabled || !isTtsReady || isShowingResult) return;
    for (final number in ['Tiga', 'Dua', 'Satu']) {
      if (!voiceEnabled || !mounted) return;
      await flutterTts.speak(number);
    }
  }

  void startGuidanceTimer() {
    guidanceTimer?.cancel();
    secondsWithoutMoney = 0;
    guidanceTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || isShowingResult || isCandidateDetected) return;
      secondsWithoutMoney++;

      if (secondsWithoutMoney >= 10) {
        secondsWithoutMoney = 0;
        await speakInstruction(guidanceMessage);
      }
    });
  }

  void stopGuidanceTimer() {
    guidanceTimer?.cancel();
    guidanceTimer = null;
  }

  // ==============================
  // INISIALISASI KAMERA
  // ==============================

  Future<void> initializeCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        if (!mounted) return;

        setState(() {
          cameraError = 'Kamera tidak ditemukan';
          scanStatus = 'KAMERA TIDAK DITEMUKAN';
        });

        return;
      }

      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      cameraController = controller;

      await controller.initialize();

      if (!mounted) return;

      setState(() {
        isCameraInitialized = true;
      });

      tryStartAutoScan();
    } catch (e) {
      debugPrint('Error kamera: $e');

      if (!mounted) return;

      setState(() {
        cameraError = 'Gagal membuka kamera: $e';
        scanStatus = 'KAMERA BERMASALAH';
        scanMessage = 'Periksa izin kamera perangkat.';
      });
    }
  }

  // ==============================
  // INISIALISASI MODEL ONNX
  // ==============================

  Future<void> initializeModel() async {
    try {
      await onnxService.initialize();

      if (!mounted) return;

      setState(() {
        isModelInitialized = true;
      });

      debugPrint('Model ONNX siap digunakan!');

      tryStartAutoScan();
    } catch (e) {
      debugPrint('Gagal memuat model: $e');

      if (!mounted) return;

      setState(() {
        scanStatus = 'MODEL GAGAL DIMUAT';
        scanMessage = 'Periksa file model ONNX.';
      });
    }
  }

  // ==============================
  // MEMULAI AUTO SCAN
  // ==============================

  void tryStartAutoScan() {
    if (!isCameraInitialized || !isModelInitialized) {
      return;
    }

    if (scanTimer != null) return;

    setState(() {
      scanStatus = 'SIAP MEMINDAI';
      scanMessage = 'Masukkan uang ke dalam bingkai pemindaian.';
    });

    scanTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!isFrozen) processScanFrame();
    });
    startGuidanceTimer();

    debugPrint('Auto scan dimulai!');
  }

  // ==============================
  // MENGHITUNG PERBEDAAN GAMBAR
  // ==============================

  double calculateImageDifference(Float32List first, Float32List second) {
    double totalDifference = 0;
    int count = 0;

    for (int y = 0; y < 224; y += 8) {
      for (int x = 0; x < 224; x += 8) {
        final index = (y * 224 + x) * 3;

        for (int c = 0; c < 3; c++) {
          totalDifference += (first[index + c] - second[index + c]).abs();

          count++;
        }
      }
    }

    return totalDifference / count;
  }

  // ==============================
  // RESET HASIL SCAN
  // ==============================

  void resetScan() {
    previousFrame = null;
    stableCount = 0;
    lastLabel = null;
    hasAnnounced = false;
  }

  // ==============================
  // PROSES PEMINDAIAN
  // ==============================

  Future<void> processScanFrame() async {
    if (isProcessing ||
        isFrozen ||
        isShowingResult ||
        !isCameraInitialized ||
        !isModelInitialized ||
        cameraController == null ||
        !cameraController!.value.isInitialized ||
        cameraController!.value.isTakingPicture) {
      return;
    }

    isProcessing = true;

    try {
      // 1. Ambil frame kamera
      final XFile photo = await cameraController!.takePicture();
      final Uint8List imageBytes = await photo.readAsBytes();

      // 2. Preprocessing
      final Float32List inputData = ImagePreprocessing.processImage(imageBytes);

      // 3. Prediksi ONNX
      final prediction = await onnxService.predict(inputData);
      final String label = prediction['label'] as String;
      final double confidence = (prediction['confidence'] as num).toDouble();
      final double margin = (prediction['margin'] as num).toDouble();
      final String status = prediction['status'] as String;

      debugPrint(
          'Prediksi: $label | conf: $confidence | margin: $margin | status: $status');

      // 4a. Bukan uang
      if (status == 'not_money') {
        resetScan();
        isCandidateDetected = false;
        guidanceMessage = 'Itu bukan uang. Silakan arahkan kamera ke uang.';

        if (!mounted) return;
        setState(() {
          scanStatus = 'BUKAN UANG';
          scanMessage = 'Arahkan kamera ke uang.';
        });
        return;
      }

      // 4b. Model tidak yakin: jangan menebak nominal
      if (status == 'unsure') {
        resetScan();
        isCandidateDetected = false;
        guidanceMessage =
            'Uang kurang jelas. Ratakan uang dan pastikan cahaya cukup.';

        if (!mounted) return;
        setState(() {
          scanStatus = 'KURANG JELAS';
          scanMessage = 'Ratakan uang dan pastikan cahaya cukup.';
        });
        return;
      }

      // Dari sini status == 'money'
      guidanceMessage = 'Silakan arahkan uang ke kamera.';

      // 5. Cek stabilitas gambar dan label
      if (previousFrame == null) {
        stableCount = 1;
      } else {
        final difference = calculateImageDifference(previousFrame!, inputData);

        debugPrint('Perbedaan gambar: $difference');

        if (difference <= 22 && label == lastLabel) {
          stableCount++;
        } else {
          stableCount = 1;
          hasAnnounced = false;
        }
      }

      previousFrame = inputData;
      lastLabel = label;

      debugPrint('Sampel stabil: $stableCount');

      // 6. Beberapa sampel stabil berturut-turut -> freeze frame dan hasil
      if (stableCount >= requiredStable && !hasAnnounced) {
        hasAnnounced = true;
        isCandidateDetected = true;
        isFrozen = true;
        frozenFrameBytes = imageBytes;
        secondsWithoutMoney = 0;

        stopGuidanceTimer();
        await flutterTts.stop();
        isSpeaking = false;

        if (mounted) {
          setState(() {
            scanStatus = 'UANG TERDETEKSI';
            scanMessage = 'Gambar dikunci. Mengenali nominal...';
          });
        }

        debugPrint('FRAME DI-FREEZE: $label');

        if (voiceEnabled && isTtsReady) {
          await speakCountdown();
        }

        if (!mounted) return;
        await showResultPopup(label);
      } else {
        if (stableCount == 1 && !isCandidateDetected) {
          isCandidateDetected = true;
          secondsWithoutMoney = 0;
          stopGuidanceTimer();

          if (voiceEnabled) {
            await speakInstruction('Uang terdeteksi, mohon tahan posisi.');
          }
        }

        if (mounted && !hasAnnounced) {
          setState(() {
            scanStatus = 'MEMERIKSA UANG...';
            scanMessage = 'Menstabilkan gambar $stableCount/$requiredStable.';
          });
        }
      }
    } catch (e) {
      debugPrint('Kesalahan pemindaian: $e');
      resetScan();
      isCandidateDetected = false;
      isFrozen = false;
      frozenFrameBytes = null;

      if (mounted) {
        setState(() {
          scanStatus = 'PEMINDAIAN TERGANGGU';
          scanMessage = 'Mencoba memindai kembali.';
        });
      }
    } finally {
      isProcessing = false;
    }
  }

  // ==============================
  // POPUP HASIL DETEKSI
  // ==============================

  String nominalText(String label) {
    switch (label) {
      case 'duaribu':
        return 'Rp2.000';
      case 'duapuluhribu':
        return 'Rp20.000';
      case 'limaribu':
        return 'Rp5.000';
      case 'limapuluhribu':
        return 'Rp50.000';
      case 'sepuluhribu':
        return 'Rp10.000';
      case 'seratusribu':
        return 'Rp100.000';
      case 'seribu':
        return 'Rp1.000';
      default:
        return 'Nominal tidak diketahui';
    }
  }

  Future<void> showResultPopup(String label) async {
    if (!mounted || isShowingResult) return;

    isShowingResult = true;
    scanTimer?.cancel();
    scanTimer = null;
    stopGuidanceTimer();
    await flutterTts.stop();
    isSpeaking = false;

    setState(() {
      scanStatus = 'UANG TERDETEKSI';
      scanMessage = 'Nominal berhasil dikenali.';
    });

    // Suara nominal diputar bersamaan dengan popup.
    if (voiceEnabled) {
      unawaited(audioService.playNominal(label));
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: darkCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF75D69C),
                size: 64,
              ),
              const SizedBox(height: 16),
              const Text(
                'UANG TERDETEKSI',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                nominalText(label),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ketuk di luar popup untuk memindai uang berikutnya.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('TUTUP', style: TextStyle(color: purple)),
            ),
          ],
        );
      },
    );

    await audioService.stopAudio();
    if (!mounted) return;

    resetScan();
    isCandidateDetected = false;
    isShowingResult = false;
    isFrozen = false;
    frozenFrameBytes = null;
    secondsWithoutMoney = 0;

    setState(() {
      scanStatus = 'SIAP MEMINDAI';
      scanMessage = 'Arahkan uang ke kamera.';
    });

    // Langsung aktif kembali; instruksi pencarian baru berbunyi setelah 10 detik.
    tryStartAutoScan();
  }

  Widget _speedOption(
    BuildContext dialogContext,
    StateSetter setModalState,
    double speed,
    String title,
  ) {
    return RadioListTile<double>(
      value: speed,
      groupValue: audioSpeed,
      activeColor: purple,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: Text(
        '${speed}x',
        style: const TextStyle(color: Colors.white54),
      ),
      onChanged: (value) async {
        if (value == null) return;

        setState(() {
          audioSpeed = value;
        });

        setModalState(() {});

        await audioService.setSpeechRate(value);

        // Sesuaikan kecepatan instruksi TTS juga
        double ttsRate;

        switch (value) {
          case 0.75:
            ttsRate = 0.35;
            break;
          case 1.0:
            ttsRate = 0.45;
            break;
          case 1.25:
            ttsRate = 0.55;
            break;
          case 1.5:
            ttsRate = 0.65;
            break;
          default:
            ttsRate = 0.45;
        }

        await flutterTts.setSpeechRate(ttsRate);

        Navigator.pop(dialogContext);
      },
    );
  }

  // ==============================
  // PENGATURAN
  // ==============================

  void openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: darkCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(
                    child: Text(
                      'Pengaturan',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  SwitchListTile(
                    value: voiceEnabled,
                    activeThumbColor: purple,
                    title: const Text('Panduan Suara'),
                    subtitle: const Text('Aktifkan instruksi suara aplikasi'),
                    secondary: const Icon(Icons.volume_up),
                    onChanged: (value) {
                      setState(() {
                        voiceEnabled = value;
                      });

                      setModalState(() {});
                    },
                  ),

                  const Divider(height: 28),

                  ListTile(
                    leading: const Icon(Icons.speed),
                    title: const Text('Kecepatan Suara'),
                    subtitle: Text(
                      audioSpeed == 0.75
                          ? 'Lambat'
                          : audioSpeed == 1.0
                          ? 'Normal'
                          : audioSpeed == 1.25
                          ? 'Cepat'
                          : 'Sangat cepat',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (dialogContext) {
                          return AlertDialog(
                            backgroundColor: darkCard,
                            title: const Text(
                              'Kecepatan Suara',
                              style: TextStyle(color: Colors.white),
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _speedOption(
                                  dialogContext,
                                  setModalState,
                                  0.75,
                                  'Lambat',
                                ),
                                _speedOption(
                                  dialogContext,
                                  setModalState,
                                  1.0,
                                  'Normal',
                                ),
                                _speedOption(
                                  dialogContext,
                                  setModalState,
                                  1.25,
                                  'Cepat',
                                ),
                                _speedOption(
                                  dialogContext,
                                  setModalState,
                                  1.5,
                                  'Sangat cepat',
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ==============================
  // DISPOSE
  // ==============================

  @override
  void dispose() {
    scanTimer?.cancel();
    stopGuidanceTimer();

    flutterTts.stop();
    cameraController?.dispose();

    onnxService.dispose();

    audioService.dispose();

    super.dispose();
  }

  // ==============================
  // TAMPILAN UTAMA
  // ==============================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            children: [
              // HEADER
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: purple.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Image.asset(
                      'assets/icon/icon.png',
                      width: 28,
                      height: 28,
                    ),
                  ),

                  const SizedBox(width: 12),

                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RupiahScan',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Deteksi Nominal Uang Rupiah',
                          style: TextStyle(fontSize: 12, color: Colors.white60),
                        ),
                      ],
                    ),
                  ),

                  // TOMBOL SUARA
                  IconButton(
                    tooltip: 'Aktif/nonaktifkan suara',
                    onPressed: () {
                      setState(() {
                        voiceEnabled = !voiceEnabled;
                      });
                    },
                    icon: Icon(
                      voiceEnabled
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_rounded,
                      color: voiceEnabled ? purple : Colors.white54,
                      size: 27,
                    ),
                  ),

                  // TOMBOL PENGATURAN
                  IconButton(
                    tooltip: 'Pengaturan',
                    onPressed: openSettings,
                    icon: const Icon(Icons.settings_rounded, size: 26),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // CAMERA PREVIEW
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF292832),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: cameraError.isNotEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Text(
                                      cameraError,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                )
                              : isCameraInitialized && cameraController != null
                              ? (isFrozen && frozenFrameBytes != null
                                    ? Image.memory(
                                        frozenFrameBytes!,
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        height: double.infinity,
                                      )
                                    : CameraPreview(cameraController!))
                              : const Center(
                                  child: CircularProgressIndicator(
                                    color: Color(0xFF8957E5),
                                  ),
                                ),
                        ),
                      ),

                      // BINGKAI SCAN
                      Positioned(
                        left: 25,
                        right: 25,
                        top: 60,
                        bottom: 60,
                        child: CustomPaint(
                          painter: ScanFramePainter(color: purple),
                        ),
                      ),

                      // LABEL AREA SCAN
                      Positioned(
                        top: 25,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.center_focus_strong,
                                color: Colors.white,
                                size: 17,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'AREA PEMINDAIAN',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // STATUS SCANNER
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [purple, const Color(0xFF6235B5)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.volume_up_rounded,
                      color: Colors.white,
                      size: 34,
                    ),

                    const SizedBox(width: 10),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            scanStatus,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),

                          const SizedBox(height: 1),

                          Text(
                            scanMessage,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // FOOTER
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.accessibility_new,
                    color: Colors.white54,
                    size: 18,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Dirancang untuk memudahkan tunanetra',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),

              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ==============================
// CUSTOM BINGKAI PEMINDAIAN
// ==============================

class ScanFramePainter extends CustomPainter {
  final Color color;

  ScanFramePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const corner = 35.0;

    // Kiri atas
    canvas.drawLine(const Offset(0, corner), const Offset(0, 0), paint);

    canvas.drawLine(const Offset(0, 0), const Offset(corner, 0), paint);

    // Kanan atas
    canvas.drawLine(
      Offset(size.width - corner, 0),
      Offset(size.width, 0),
      paint,
    );

    canvas.drawLine(Offset(size.width, 0), Offset(size.width, corner), paint);

    // Kiri bawah
    canvas.drawLine(
      Offset(0, size.height - corner),
      Offset(0, size.height),
      paint,
    );

    canvas.drawLine(Offset(0, size.height), Offset(corner, size.height), paint);

    // Kanan bawah
    canvas.drawLine(
      Offset(size.width - corner, size.height),
      Offset(size.width, size.height),
      paint,
    );

    canvas.drawLine(
      Offset(size.width, size.height - corner),
      Offset(size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant ScanFramePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
