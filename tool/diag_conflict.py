import json
import os
import sqlite3
import sys
import urllib.request

sys.stdout.reconfigure(encoding='utf-8')

PC = os.path.join(os.path.expanduser('~'), 'Documents', 'MoonNote', 'moon_note.db')


def get(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.loads(r.read().decode('utf-8'))


def pc_summary():
    c = sqlite3.connect(PC)
    rows = {
        'nodes': c.execute('select count(*) from nodes').fetchone()[0],
        'content': c.execute('select count(*) from note_content').fetchone()[0],
        'images': c.execute('select count(*) from note_images').fetchone()[0],
    }
    st = dict(c.execute("select key, value from app_settings").fetchall())
    c.close()
    return rows, st


def main():
    rows, st = pc_summary()
    print('PC 计数:', rows)
    print('PC 水位线 last_sync_time =', st.get('last_sync_time'))
    print('PC sync_key =', st.get('sync_key'))
    print('PC sync_host =', st.get('sync_host'), st.get('sync_port'))

    # 该节点在电脑库里的样子
    c = sqlite3.connect(PC)
    n = c.execute(
        'select id, title, modified_at, content_modified_at, is_deleted '
        'from nodes where id = ?', ('1793531617002',)
    ).fetchone()
    print('\nPC 节点 1793531617002:', n)
    if n:
        cc = c.execute(
            'select modified_at, length(content) from note_content where note_id = ?',
            ('1793531617002',)
        ).fetchone()
        print('PC 该节点正文: modified_at=%s, 长度=%s' % (cc if cc else ('无', '无')))

    # 重复标题检查(冲突副本会长成同名)
    print('\n=== 电脑库里标题重复的笔记(冲突副本痕迹) ===')
    dups = c.execute(
        "select title, count(*) as n, group_concat(id) from nodes "
        "where type='note' and is_deleted=0 group by title having n > 1 order by n desc"
    ).fetchall()
    for t, n_, ids in dups[:15]:
        print('  %-30s x%d  ids=%s' % (t, n_, ids))
    if not dups:
        print('  (没有重名)')
    c.close()

    # 手机侧
    try:
        ph = get('http://127.0.0.1:9091/sync/summary?since=0')
        print('\nPHONE summary keys:', sorted(ph.keys())[:12])
        print('PHONE nodes/content/images =',
              ph.get('nodes'), ph.get('content'), ph.get('images'),
              'watermark=', ph.get('last_sync_time') or ph.get('watermark'))
    except Exception as e:
        print('手机 summary 失败:', e)

    # 两边该节点的状态
    try:
        m = get('http://127.0.0.1:9091/sync/manifest?since=0')
        items = m if isinstance(m, list) else m.get('items') or m.get('nodes') or []
        hit = [i for i in items if i.get('id') == '1793531617002']
        print('\nPHONE manifest 里的该节点:', json.dumps(hit, ensure_ascii=False))
    except Exception as e:
        print('手机 manifest 失败:', e)


main()
