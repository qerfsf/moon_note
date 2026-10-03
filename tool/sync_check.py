"""同步一致性检查:比对电脑端与手机端的数据,给出逐行差异。

用法(需要手机已 USB 连接且端口转发已建立):
    python tool/sync_check.py
    python tool/sync_check.py --pc-port 9090 --phone-port 9091

为什么需要它:手动点同步只会告诉你「成功」,而「成功」并不代表两端真的一样。
这个脚本用 /sync/summary 的计数与指纹、/sync/manifest 的逐行内容做交叉验证,
两端不一致时会直接列出是哪几行不同。

注意 /sync/manifest 是紧凑格式 `id|modified_at|is_deleted|title`,
不是完整数据行 —— 指纹相同时逐行比对才有意义。
"""
import argparse
import json
import sys
import urllib.request

# Windows 控制台默认是 GBK,直接 print '✓' 会 UnicodeEncodeError。
# 强制按 UTF-8 输出,免得工具本身在最后一步崩掉(比对结果其实已经出来了)。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding='utf-8')
    except (AttributeError, ValueError):
        pass


def get(port, path, timeout=20):
    url = 'http://127.0.0.1:%d/sync/%s' % (port, path)
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def fetch(port):
    return get(port, 'summary'), get(port, 'manifest')


def show(name, s):
    c = s['counts']
    print('  %-6s v%s  同步码=%s' % (name, s['version'], s['sync_key']))
    print('         计数 nodes=%d notes=%d folders=%d 回收站=%d content=%d images=%d'
          % (c['nodes'], c['notes'], c['folders'], c['recycle_bin'],
             c['content'], c['images']))
    print('         指纹 %s / %s / %s' % (s['fp_nodes'], s['fp_content'], s['fp_images']))
    print('         水位线 %d' % s['watermark'])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pc-port', type=int, default=9090)
    ap.add_argument('--phone-port', type=int, default=9091)
    args = ap.parse_args()

    try:
        pc_s, pc_m = fetch(args.pc_port)
        ph_s, ph_m = fetch(args.phone_port)
    except Exception as e:
        print('读取失败: %s' % e)
        print('检查手机是否已连接,以及 `adb forward tcp:%d tcp:9090` 是否已建立。'
              % args.phone_port)
        return 2

    print('=== 两端概况 ===')
    show('PC', pc_s)
    show('PHONE', ph_s)

    print('\n=== 配对与水位线 ===')
    ok_key = pc_s['sync_key'] == ph_s['sync_key']
    print('  sync_key 一致: %s (%s)' % ('是' if ok_key else '否!', pc_s['sync_key']))
    gap = pc_s['watermark'] - ph_s['watermark']
    print('  水位线差: %d ms%s' % (gap, '' if abs(gap) < 60000 else '  ← 偏大,注意时钟'))

    same_counts = pc_s['counts'] == ph_s['counts']
    same_fp = (pc_s['fp_nodes'] == ph_s['fp_nodes']
               and pc_s['fp_content'] == ph_s['fp_content']
               and pc_s['fp_images'] == ph_s['fp_images'])
    print('  计数一致: %s' % ('是' if same_counts else '否!'))
    print('  指纹一致: %s' % ('是' if same_fp else '否!'))

    print('\n=== 逐行差异 ===')
    total = 0
    for key in ('nodes', 'content', 'images'):
        a, b = pc_m.get(key, []), ph_m.get(key, [])
        diff = set(a) ^ set(b)
        total += len(diff)
        print('  %-8s PC=%-4d 手机=%-4d 差异=%d' % (key, len(a), len(b), len(diff)))
        for row in sorted(diff)[:15]:
            side = '仅PC  ' if row in set(a) - set(b) else '仅手机'
            print('      %s %s' % (side, row))
        if len(diff) > 15:
            print('      …还有 %d 行' % (len(diff) - 15))

    print('\n=== 结论 ===')
    if ok_key and same_counts and same_fp and total == 0:
        print('  ✓ 两端完全一致')
        return 0
    print('  ✗ 两端存在差异(逐行差异 %d 行),需要同步' % total)
    return 1


if __name__ == '__main__':
    sys.exit(main())
