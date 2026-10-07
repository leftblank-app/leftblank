#!/usr/bin/env python3
# LB-019: summarize build/visual-editing/lb019-*.json (see docs/visual-editing.md).
import json,sys
d=json.load(open(sys.argv[1]))
for k,v in sorted(d.items()):
    if '.large.' not in k: continue
    print(k)
    print('  open %.0f draw %.0f h0 %.0f hfull %.0f full %.0f (slices %s) mem %.0f/%.0f/%.0f scroll p95 %.2f typing med/p95/max %.2f/%.2f/%.2f' % (v['open_ms'],v['first_draw_ms'],v['height_initial'],v['height_full'],v['full_layout_ms'],v.get('full_layout_slices'),v['memory_before_mib'],v['memory_open_mib'],v['memory_full_layout_mib'],v['scroll_draw_ms']['p95'],v['typing_ms']['median'],v['typing_ms']['p95'],v['typing_ms']['max']))
    for ph in ['jumps_native','jumps_precise','jumps_native_after_full_layout']:
        if ph in v:
            j=v[ph]; imm=[(s.get('immediate_in_viewport'), s.get('immediate_hit_error')) for s in j['samples']]
            print('  %-32s ms med/max %.1f/%.1f visible %s maxhit %s heights %s immediate %s passes %s' % (ph, j['ms']['median'], j['ms']['max'], j['all_visible'], j['max_hit_error'], [round(x) for x in j['height_range']], [(a, b) for a,b in imm if a is False or (b or 0) != 0], [s.get('passes') for s in j['samples']]))
    extra={x:v[x] for x in ['full_plan_ms','session_open_ms','full_plan_apply_ms','full_plan_only_ms','conceals','replacements','typing_plan_ms','typing_nodes_ms','undo_restores_source','full_layout_slice_ms'] if x in v}
    print('  ',extra)
