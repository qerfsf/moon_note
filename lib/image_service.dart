import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'database.dart';

class ImageService {
  static final ImageService instance = ImageService._();
  ImageService._();

  Future<Directory> _imagesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}moon_note_images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _noteImagesDir(String noteId) async {
    final base = await _imagesDir();
    final dir = Directory('${base.path}${Platform.pathSeparator}$noteId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Copy an image file into the app's storage, create a DB record.
  /// Returns the generated image_id.
  Future<String> saveImage(String noteId, String sourcePath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('源文件不存在: $sourcePath');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'img_$now';
    final ext = sourcePath.split('.').last;
    final filename = '$id.$ext';

    final targetDir = await _noteImagesDir(noteId);
    final targetPath = '${targetDir.path}${Platform.pathSeparator}$filename';
    await sourceFile.copy(targetPath);

    final fileSize = await sourceFile.length();

    final db = await DatabaseHelper.instance.database;
    await db.insert('note_images', {
      'id': id,
      'note_id': noteId,
      'filename': filename,
      'width': null,
      'height': null,
      'file_size': fileSize,
      'created_at': now,
      'modified_at': now,
    });

    return id;
  }

  /// Get the local file path for an image by its ID.
  Future<String?> getImagePath(String imageId) async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.query(
      'note_images',
      where: 'id = ?',
      whereArgs: [imageId],
      limit: 1,
    );
    if (result.isEmpty) return null;

    final row = result.first;
    final noteId = row['note_id'] as String;
    final filename = row['filename'] as String;
    final base = await _imagesDir();
    final path = '${base.path}${Platform.pathSeparator}$noteId${Platform.pathSeparator}$filename';
    if (await File(path).exists()) return path;
    return null;
  }

  /// Get all images for a note.
  Future<List<Map<String, dynamic>>> getImagesForNote(String noteId) async {
    final db = await DatabaseHelper.instance.database;
    return await db.query(
      'note_images',
      where: 'note_id = ?',
      whereArgs: [noteId],
    );
  }

  /// Delete a single image (file + DB record).
  Future<void> deleteImage(String imageId) async {
    final path = await getImagePath(imageId);
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    final db = await DatabaseHelper.instance.database;
    await db.delete('note_images', where: 'id = ?', whereArgs: [imageId]);
  }

  /// Delete all images for a note (files + DB records).
  Future<void> deleteImagesForNote(String noteId) async {
    final images = await getImagesForNote(noteId);
    for (final img in images) {
      await deleteImage(img['id'] as String);
    }
    // Clean up the note's image directory
    try {
      final dir = await _noteImagesDir(noteId);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// Delete multiple notes' images (used in batch delete).
  Future<void> deleteImagesForNotes(List<String> noteIds) async {
    for (final noteId in noteIds) {
      await deleteImagesForNote(noteId);
    }
  }

  /// Get all image metadata that were modified after a given timestamp.
  /// Used for sync.
  Future<List<Map<String, dynamic>>> getImagesModifiedAfter(int timestamp) async {
    final db = await DatabaseHelper.instance.database;
    return await db.query(
      'note_images',
      where: 'modified_at > ?',
      whereArgs: [timestamp],
    );
  }

  /// Upsert image metadata from sync. Does NOT write the file.
  Future<void> upsertImageMeta(Map<String, dynamic> meta) async {
    final db = await DatabaseHelper.instance.database;
    final id = meta['id'] as String;
    final existing = await db.query(
      'note_images',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('note_images', meta);
    } else {
      final localModified = existing.first['modified_at'] as int;
      final remoteModified = meta['modified_at'] as int;
      if (remoteModified > localModified) {
        await db.update(
          'note_images',
          meta,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
  }

  /// Save image file bytes directly (used when downloading from sync).
  Future<void> saveImageBytes(String noteId, String filename, List<int> bytes) async {
    final dir = await _noteImagesDir(noteId);
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(bytes);
  }

  /// Read image file bytes (used for sync upload).
  Future<List<int>?> readImageBytes(String imageId) async {
    final path = await getImagePath(imageId);
    if (path == null) return null;
    return await File(path).readAsBytes();
  }
}
