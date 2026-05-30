# Moon Note

简洁的 Flutter 笔记应用，支持 Markdown 编辑和预览。

## 功能

- 创建笔记和文件夹，支持无限嵌套
- Markdown 编辑，工具栏快捷插入格式
- 一键切换编辑/预览模式，预览记忆
- 多选批量操作（移动、删除、恢复）
- 置顶、排序（修改时间/标题/创建时间）
- 标题和内容全文搜索
- 长按菜单 + 水平滑动快速进入多选
- 回收站（软删除、恢复、清空）
- 字数统计

## 运行

```
cd D:\moon_note
flutter run -d windows          # Windows
flutter run -d <device-id>    # Android
```

## 技术栈

- **框架：** Flutter 3.32+ / Dart
- **数据库：** SQLite (sqflite)
- **Markdown 渲染：** flutter_markdown
- **平台：** Windows + Android

## 数据库结构

| 表 | 说明 |
|---|---|
| nodes | 文件夹和笔记 |
| note_content | 笔记正文 |
| fts_content | 全文搜索索引 |
| reminders | 提醒 |
| note_links | 笔记链接 |
| app_settings | 应用设置 |
