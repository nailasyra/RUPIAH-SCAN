
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class ImagePreprocessing {
  static const int imageSize = 224;

  static Float32List processImage(Uint8List imageBytes) {
    // Decode foto dari kamera
    final decodedImage = img.decodeImage(imageBytes);

    if (decodedImage == null) {
      throw Exception('Gagal membaca gambar dari kamera');
    }

    // Koreksi orientasi gambar
    final orientedImage = img.bakeOrientation(decodedImage);

    // Ubah ukuran menjadi 224 x 224
    final resizedImage = img.copyResize(
      orientedImage,
      width: imageSize,
      height: imageSize,
      interpolation: img.Interpolation.linear, // training (TensorFlow) memakai bilinear
    );

    // Siapkan data RGB dalam format NHWC
    final inputData = Float32List(imageSize * imageSize * 3);

    var index = 0;

    for (var y = 0; y < imageSize; y++) {
      for (var x = 0; x < imageSize; x++) {
        final pixel = resizedImage.getPixel(x, y);

        inputData[index++] = pixel.r.toDouble();
        inputData[index++] = pixel.g.toDouble();
        inputData[index++] = pixel.b.toDouble();
      }
    }

    return inputData;
  }
}
