
import 'package:audioplayers/audioplayers.dart';

class AudioService {
  final AudioPlayer _audioPlayer = AudioPlayer();

  double _speechRate = 1.0;

  double get speechRate => _speechRate;

  final Map<String, String> _audioFiles = {
    'duak': 'audio/dua ribu rupiah.mp3',
    'duapuluhk': 'audio/dua puluh ribu rupiah.mp3',
    'limak': 'audio/lima ribu rupiah.mp3',
    'limapuluhk': 'audio/lima puluh ribu rupiah.mp3',
    'sepuluhk': 'audio/sepuluh ribu rupiah.mp3',
    'seratusk': 'audio/seratus ribu rupiah.mp3',
    'seribuk': 'audio/seribu rupiah.mp3',
  };

  // Mengatur kecepatan suara
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.5, 2.0);
    await _audioPlayer.setPlaybackRate(_speechRate);
  }

  Future<void> playNominal(String label) async {
    final audioPath = _audioFiles[label];

    if (audioPath == null) {
      print('Audio untuk $label tidak ditemukan');
      return;
    }

    await _audioPlayer.stop();
    await _audioPlayer.setPlaybackRate(_speechRate);
    await _audioPlayer.play(AssetSource(audioPath));
  }

  Future<void> stopAudio() async {
    await _audioPlayer.stop();
  }

  Future<void> dispose() async {
    await _audioPlayer.dispose();
  }
}
