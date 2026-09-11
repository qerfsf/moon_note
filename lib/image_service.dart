import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'database.dart';

class ImageService {
  static final ImageService instance = ImageService._();
  ImageService._();

  static const _legacyDirName = 'moon_note_images';

  /// 用户可见的图片根目录: <我的文档>/MoonNote/images
  Future<Directory> _imagesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(
        '${appDir.path}${Platform.pathSeparator}MoonNote${Platform.pathSeparator}images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 旧版本使用的目录: <我的文档>/moon_note_images(仅用于兼容读取)
  Future<Directory> _legacyImagesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(
        '${appDir.path}${Platform.pathSeparator}$_legacyDirName');
  }

  Future<Directory> _noteImagesDir(String noteId) async {
    final base = await _imagesDir();
    final dir = Directory('${base.path}${Platform.pathSeparator}$noteId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 读取图片头信息:格式、尺寸、是否含透明通道(不依赖任何图像库)。
  /// 支持 PNG / JPEG / GIF / WebP / BMP。
  static Future<Map<String, dynamic>> probeImage(String path) async {
    final result = <String, dynamic>{
      'format': '未知',
      'width': 0,
      'height': 0,
      'hasAlpha': false,
    };
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length < 26) return result;
      int u32(int o) =>
          (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3];
      int u16(int o) => (bytes[o] << 8) | bytes[o + 1];
      final isPng = bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E;
      if (isPng) {
        result['format'] = 'PNG';
        result['width'] = u32(16);
        result['height'] = u32(20);
        final colorType = bytes[25];
        // 4=灰度+alpha, 6=RGBA
        var hasAlpha = colorType == 4 || colorType == 6;
        if (!hasAlpha) {
          // 调色板 PNG 可能带 tRNS 透明块
          final text = String.fromCharCodes(bytes.take(4096));
          if (text.contains('tRNS')) hasAlpha = true;
        }
        result['hasAlpha'] = hasAlpha;
        return result;
      }
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        result['format'] = 'JPEG';
        var offset = 2;
        while (offset + 9 < bytes.length) {
          if (bytes[offset] != 0xFF) {
            offset++;
            continue;
          }
          final marker = bytes[offset + 1];
          final len = u16(offset + 2);
          if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
            result['height'] = u16(offset + 5);
            result['width'] = u16(offset + 7);
            break;
          }
          offset += 2 + len;
        }
        result['hasAlpha'] = false; // JPEG 不支持透明通道
        return result;
      }
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        result['format'] = 'GIF';
        result['width'] = bytes[6] | (bytes[7] << 8);
        result['height'] = bytes[8] | (bytes[9] << 8);
        // 存在图形控制扩展即可能带透明
        final text = String.fromCharCodes(bytes.take(8192));
        result['hasAlpha'] = text.contains('NETSCAPE') || bytes.length > 800;
        return result;
      }
      if (bytes.length > 30 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46) {
        result['format'] = 'WebP';
        final fourCC = String.fromCharCodes(bytes.sublist(12, 16));
        if (fourCC == 'VP8X') {
          final flags = bytes[20];
          result['hasAlpha'] = (flags & 0x10) != 0;
          result['width'] = 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16);
          result['height'] = 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16);
        } else if (fourCC == 'VP8L') {
          final b0 = bytes[21], b1 = bytes[22], b2 = bytes[23], b3 = bytes[24];
          result['hasAlpha'] = (b3 & 0x10) != 0;
          result['width'] = 1 + (((b1 & 0x3F) << 8) | b0);
          result['height'] = 1 + (((b3 & 0xF) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
        } else {
          result['hasAlpha'] = true; // 保守判断
        }
        return result;
      }
      if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
        result['format'] = 'BMP';
        result['width'] = bytes[18] | (bytes[19] << 8) | (bytes[20] << 16);
        result['height'] = bytes[22] | (bytes[23] << 8) | (bytes[24] << 16);
        final bpp = bytes[28] | (bytes[29] << 8);
        result['hasAlpha'] = bpp == 32;
        return result;
      }
    } catch (_) {}
    return result;
  }

  /// 图片信息文本,如 "PNG · 1024×1024 · 含透明通道"。
  static String describeImage(Map<String, dynamic> info) {
    final parts = <String>['${info['format']}'];
    final w = (info['width'] as int?) ?? 0;
    final h = (info['height'] as int?) ?? 0;
    if (w > 0 && h > 0) parts.add('${w}×${h}');
    parts.add(info['hasAlpha'] == true ? '含透明通道' : '无透明通道');
    return parts.join(' · ');
  }

  /// 去掉文件名中不合法的字符,避免路径问题。
  static String sanitizeFileName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (n.isEmpty) n = 'image';
    if (n.length > 120) n = n.substring(0, 120);
    return n;
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
    final originalName =
        sourcePath.split(Platform.pathSeparator).last.split('/').last;
    final ext = originalName.contains('.') ? originalName.split('.').last : 'jpg';
    // 保留原始文件名,方便在资源管理器里辨认: img_<ts>_<原名>.jpg
    final filename = '${id}_${sanitizeFileName(originalName)}';

    final targetDir = await _noteImagesDir(noteId);
    final targetPath = '${targetDir.path}${Platform.pathSeparator}$filename';
    await sourceFile.copy(targetPath);

    final fileSize = await sourceFile.length();
    // 记录真实尺寸与透明通道信息(同步到对端)
    final info = await probeImage(targetPath);

    final db = await DatabaseHelper.instance.database;
    await db.insert('note_images', {
      'id': id,
      'note_id': noteId,
      'filename': filename,
      'width': (info['width'] as int?) == 0 ? null : info['width'],
      'height': (info['height'] as int?) == 0 ? null : info['height'],
      'file_size': fileSize,
      'created_at': now,
      'modified_at': now,
    });

    // ext 仅用于兜底,确保变量被使用
    assert(ext.isNotEmpty);
    return id;
  }

  /// Get the local file path for an image by its ID.
  /// 先查新目录;找不到再回退旧目录(兼容历史图片)。
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
    final path =
        '${base.path}${Platform.pathSeparator}$noteId${Platform.pathSeparator}$filename';
    if (await File(path).exists()) return path;

    // 旧目录里的图片:自动迁移到新目录(用户可见、集中存放)
    final legacyBase = await _legacyImagesDir();
    final legacyPath =
        '${legacyBase.path}${Platform.pathSeparator}$noteId${Platform.pathSeparator}$filename';
    final legacyFile = File(legacyPath);
    if (await legacyFile.exists()) {
      try {
        final targetDir = await _noteImagesDir(noteId);
        final newFile =
            File('${targetDir.path}${Platform.pathSeparator}$filename');
        if (!await newFile.exists()) {
          await legacyFile.copy(newFile.path);
        }
        try {
          await legacyFile.delete();
        } catch (_) {}
        return newFile.path;
      } catch (_) {
        return legacyPath; // 迁移失败时继续用旧路径读取
      }
    }

    return null;
  }

  /// 图片元数据(用于导出 Markdown 时还原文件名)。
  Future<Map<String, dynamic>?> getImageMeta(String imageId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('note_images',
        where: 'id = ?', whereArgs: [imageId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 把图片复制到指定路径(另存为)。
  Future<bool> copyImageTo(String imageId, String destPath) async {
    final src = await getImagePath(imageId);
    if (src == null) return false;
    await File(src).copy(destPath);
    return true;
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
    // 记录待传播的删除,让对端也删掉(否则两端图片记录会不一致)
    await _queuePendingDelete(imageId);
  }

  // ── 图片删除的跨设备传播 ───────────────────────────────────
  static const _pendingDeletesKey = 'pending_image_deletes_json';

  static Future<List<String>> _readPendingDeletes() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query('app_settings',
          where: 'key = ?', whereArgs: [_pendingDeletesKey]);
      if (rows.isEmpty) return [];
      final raw = rows.first['value'] as String;
      if (raw.isEmpty || raw == '[]') return [];
      return (jsonDecode(raw) as List)
          .whereType<String>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writePendingDeletes(List<String> ids) async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.rawInsert(
        'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?)',
        [_pendingDeletesKey, jsonEncode(ids)],
      );
    } catch (_) {}
  }

  static Future<void> _queuePendingDelete(String imageId) async {
    final list = await _readPendingDeletes();
    if (!list.contains(imageId)) {
      list.add(imageId);
      await _writePendingDeletes(list);
    }
  }

  /// 待传播的图片删除 id 列表(同步时带上)。
  static Future<List<String>> pendingImageDeletes() => _readPendingDeletes();

  /// 发送成功后清空待传播列表。
  static Future<void> clearPendingImageDeletes() => _writePendingDeletes([]);

  /// 应用对端传来的图片删除:删除本地文件与记录。
  Future<void> applyRemoteDelete(String imageId) async {
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
