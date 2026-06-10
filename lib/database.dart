import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

String _generateShortKey() {
  final r = Random();
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
}

String _generateUuid() {
  final r = Random();
  final hex = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20,32)}';
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('moon_note.db');
    return _database!;
  }

  static String? _resolvedDbPath;

  /// Returns the absolute database file path.
  /// On desktop, uses a fixed location under Documents\MoonNote\
  /// to avoid CWD-dependent behaviour (flutter run vs release exe).
  /// On mobile, falls back to the standard getDatabasesPath().
  static Future<String> get resolvedDatabasePath async {
    if (_resolvedDbPath != null) return _resolvedDbPath!;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final docDir = await getApplicationDocumentsDirectory();
      final moonDir = Directory(
        '${docDir.path}${Platform.pathSeparator}MoonNote',
      );
      if (!await moonDir.exists()) {
        await moonDir.create(recursive: true);
      }
      _resolvedDbPath = '${moonDir.path}${Platform.pathSeparator}moon_note.db';
    } else {
      final dbPath = await getDatabasesPath();
      _resolvedDbPath = join(dbPath, 'moon_note.db');
    }

    return _resolvedDbPath!;
  }

  /// Discover old database files from previous working-directory-relative
  /// locations.  Returns a de-duplicated list of existing files.
  static Future<List<File>> _findOldDatabases() async {
    final oldFiles = <File>[];

    // (a) The current sqflite_common_ffi default (CWD-relative)
    final oldDbPath = await getDatabasesPath();
    final oldDefault = File(join(oldDbPath, 'moon_note.db'));
    if (await oldDefault.exists()) {
      oldFiles.add(oldDefault);
    }

    // (b) Walk up from the executable directory, looking for the
    //     .dart_tool/sqflite_common_ffi/databases/ pattern.
    //     This catches both "flutter run" (project root) and
    //     double-click-launched builds (deep inside build/).
    try {
      final exeDir = Directory(Platform.resolvedExecutable).parent;
      var current = exeDir;
      for (int i = 0; i < 8; i++) {
        final candidate = File(join(
          current.path,
          '.dart_tool', 'sqflite_common_ffi', 'databases', 'moon_note.db',
        ));
        if (await candidate.exists()) {
          if (!oldFiles.any((f) => f.path == candidate.path)) {
            oldFiles.add(candidate);
          }
        }
        final parent = current.parent;
        if (parent.path == current.path) break; // reached filesystem root
        current = parent;
      }
    } catch (_) {}

    return oldFiles;
  }

  /// Migrate the largest old database to the new fixed-path location.
  /// Does nothing if the new location already contains a valid database.
  static Future<void> _migrateFromOldLocations() async {
    final newPath = await resolvedDatabasePath;
    final newFile = File(newPath);

    // Guard: if new DB already has the 'nodes' table, skip migration.
    if (await newFile.exists()) {
      try {
        final db = await openDatabase(newPath, readOnly: true);
        final result = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='nodes'",
        );
        await db.close();
        if (result.isNotEmpty) return;
      } catch (_) {
        // File exists but is not a valid SQLite DB — allow overwrite.
      }
    }

    final oldFiles = await _findOldDatabases();
    if (oldFiles.isEmpty) return;

    // Pick the database with the largest file size (most data).
    File? bestOld;
    int bestSize = 0;
    for (final f in oldFiles) {
      try {
        final size = await f.length();
        if (size > bestSize) {
          bestSize = size;
          bestOld = f;
        }
      } catch (_) {}
    }

    if (bestOld == null) return;

    // Ensure target parent directory exists.
    final targetDir = newFile.parent;
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    // Copy the database file.
    await bestOld.copy(newPath);

    // Also copy SQLite journal / WAL sidecar files if present.
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final oldJournal = File('${bestOld.path}$suffix');
      if (await oldJournal.exists()) {
        try {
          await oldJournal.copy('$newPath$suffix');
        } catch (_) {}
      }
    }
  }

  Future<Database> _initDB(String filePath) async {
    final path = await DatabaseHelper.resolvedDatabasePath;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await DatabaseHelper._migrateFromOldLocations();
    }
    return await openDatabase(path, version: 9,
        onCreate: _createDB, onUpgrade: _upgradeDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE nodes (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        parent_id TEXT,
        title TEXT NOT NULL DEFAULT '未命名',
        sort_order REAL NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        pin_order REAL NOT NULL DEFAULT 0,
        is_expanded INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        deleted_at INTEGER,
        sort_preference TEXT DEFAULT 'modified_desc',
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        is_system INTEGER NOT NULL DEFAULT 0,
        content_modified_at INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE note_content (
        note_id TEXT PRIMARY KEY,
        content TEXT NOT NULL DEFAULT '',
        modified_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE fts_content (
        note_id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE reminders (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        remind_at INTEGER NOT NULL,
        repeat_type TEXT NOT NULL DEFAULT 'once',
        repeat_day INTEGER,
        is_done INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE note_links (
        id TEXT PRIMARY KEY,
        from_note_id TEXT NOT NULL,
        to_note_id TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE note_images (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        width INTEGER,
        height INTEGER,
        file_size INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await _insertSystemFolders(db);
    await _insertDefaultSettings(db);
    await db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id, is_deleted)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_modified ON nodes(modified_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type, is_deleted)');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id, is_deleted)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_modified ON nodes(modified_at)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type, is_deleted)');
    }
    if (oldVersion < 5) {
      // Recover from any failed FTS5 migration (v3/v4)
      await db.execute('DROP TABLE IF EXISTS fts_content');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS fts_content (
          note_id TEXT PRIMARY KEY,
          title TEXT NOT NULL DEFAULT '',
          content TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.rawInsert('''
        INSERT OR IGNORE INTO fts_content(note_id, title, content)
        SELECT n.id, n.title, COALESCE(nc.content, '')
        FROM nodes n
        LEFT JOIN note_content nc ON nc.note_id = n.id
        WHERE n.type = 'note' AND n.is_deleted = 0
      ''');
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE nodes ADD COLUMN content_modified_at INTEGER NOT NULL DEFAULT 0');
      await db.execute('UPDATE nodes SET content_modified_at = modified_at');
    }
    if (oldVersion < 7) {
      await db.rawInsert("INSERT OR REPLACE INTO app_settings(key, value) VALUES('last_sync_time', '0')");
    }
    if (oldVersion < 8) {
      await db.rawInsert(
        "INSERT OR IGNORE INTO app_settings(key, value) VALUES('sync_key', ?)",
        ['moon-${_generateShortKey()}'],
      );
      await db.rawInsert(
        "INSERT OR IGNORE INTO app_settings(key, value) VALUES('device_id', ?)",
        [_generateUuid()],
      );
      await db.rawInsert(
        "INSERT OR IGNORE INTO app_settings(key, value) VALUES('device_name', ?)",
        ['Moon'],
      );
    }
    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS note_images (
          id TEXT PRIMARY KEY,
          note_id TEXT NOT NULL,
          filename TEXT NOT NULL,
          width INTEGER,
          height INTEGER,
          file_size INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          modified_at INTEGER NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_note_images_note ON note_images(note_id)');
    }
  }

  Future _insertSystemFolders(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('nodes', {
      'id': 'system_reminders',
      'type': 'folder',
      'parent_id': null,
      'title': '提醒',
      'sort_order': -2.0,
      'is_pinned': 1,
      'pin_order': -2.0,
      'is_expanded': 0,
      'is_deleted': 0,
      'is_system': 1,
      'created_at': now,
      'modified_at': now,
    });

    await db.insert('nodes', {
      'id': 'system_journal',
      'type': 'folder',
      'parent_id': null,
      'title': '日志',
      'sort_order': -1.0,
      'is_pinned': 1,
      'pin_order': -1.0,
      'is_expanded': 0,
      'is_deleted': 0,
      'is_system': 1,
      'created_at': now,
      'modified_at': now,
    });
  }

  Future _insertDefaultSettings(Database db) async {
    final defaults = {
      'theme': 'system',
      'font_size': '16',
      'recycle_bin_limit_gb': '10',
      'lan_sync_enabled': '1',
      'sync_key': 'moon-${_generateShortKey()}',
      'device_id': _generateUuid(),
      'device_name': 'Moon',
    };

    for (final entry in defaults.entries) {
      await db.insert('app_settings', {
        'key': entry.key,
        'value': entry.value,
      });
    }
  }
}
