import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('moon_note.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 2, onCreate: _createDB, onUpgrade: _upgradeDB);
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
        is_system INTEGER NOT NULL DEFAULT 0
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
    };

    for (final entry in defaults.entries) {
      await db.insert('app_settings', {
        'key': entry.key,
        'value': entry.value,
      });
    }
  }
}