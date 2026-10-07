//! LB-019 parser measurements. Usage:
//!   cargo +1.92.0 run --release --example bench -- <file.typ>...
//! Prints one JSON object per file.

use std::time::Instant;

use leftblank_syntax::LBSyntaxTree;

fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

fn stats(mut values: Vec<f64>) -> String {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pick = |q: f64| values[((values.len() - 1) as f64 * q).round() as usize];
    format!(
        "{{\"median\": {:.4}, \"p95\": {:.4}, \"max\": {:.4}}}",
        pick(0.5),
        pick(0.95),
        values[values.len() - 1]
    )
}

fn main() {
    for path in std::env::args().skip(1) {
        let text = std::fs::read_to_string(&path).expect("read fixture");
        let utf16: usize = text.encode_utf16().count();

        let mut parse = Vec::new();
        for _ in 0..5 {
            let start = Instant::now();
            let tree = LBSyntaxTree::parse(&text);
            parse.push(ms(start));
            drop(tree);
        }
        let mut tree = LBSyntaxTree::parse(&text);

        let start = Instant::now();
        let all = tree.nodes(0, usize::MAX);
        let flatten_all = ms(start);

        // A viewport-sized window (about one 1300 pt editor screen) at six offsets.
        let mut window = Vec::new();
        let mut window_nodes = 0;
        for i in 1..=6 {
            let at = utf16 * i / 7;
            let start = Instant::now();
            window_nodes = tree.nodes(at, at + 6_000).len();
            window.push(ms(start));
        }

        // 80 single-character insertions at a distant body position, each
        // followed by fetching the reparsed range's nodes (what an editor
        // needs to refresh presentation).
        let mut edit = Vec::new();
        let mut edit_only = Vec::new();
        let mut reparsed = Vec::new();
        let mut cursor = text[..text.len() / 2].encode_utf16().count();
        // Move to a line start so we type in body text, as a user would.
        let units: Vec<u16> = text.encode_utf16().collect();
        while cursor < units.len() && units[cursor] != 10 {
            cursor += 1;
        }
        cursor += 1;
        for (i, ch) in "Typing 中文 and *strong* text with #f(x) calls 😀 more"
            .chars()
            .cycle()
            .take(80)
            .enumerate()
        {
            let mut buffer = [0u8; 4];
            let with = ch.encode_utf8(&mut buffer);
            let start = Instant::now();
            let range = tree.edit(cursor, cursor, with).expect("edit");
            edit_only.push(ms(start));
            let fetched = tree.nodes(range.start, range.end).len();
            edit.push(ms(start));
            reparsed.push((range.end - range.start) as f64);
            cursor += ch.len_utf16();
            let _ = (i, fetched);
        }

        // Edits that change structure: open a call, open a raw block, insert a heading.
        let mut structural = Vec::new();
        for with in ["#item(", "```", "\n= New heading\n", "$"] {
            let start = Instant::now();
            let range = tree.edit(cursor, cursor, with).expect("edit");
            let fetched = tree
                .nodes(range.start, range.end.min(range.start + 20_000))
                .len();
            structural.push(format!(
                "{{\"insert\": {:?}, \"ms\": {:.3}, \"reparsed_utf16\": {}, \"nodes\": {}}}",
                with,
                ms(start),
                range.end - range.start,
                fetched
            ));
            let length = with.encode_utf16().count();
            tree.edit(cursor, cursor + length, "").expect("undo edit");
        }

        let mut kinds = std::collections::BTreeMap::new();
        for node in &all {
            *kinds.entry(node.kind).or_insert(0usize) += 1;
        }
        println!(
            "{{\"file\": {:?}, \"bytes\": {}, \"utf16\": {}, \"parse_ms\": {}, \"nodes\": {}, \"flatten_all_ms\": {:.3}, \"window_6000_ms\": {}, \"window_nodes\": {}, \"typing_edit_ms\": {}, \"typing_edit_plus_fetch_ms\": {}, \"typing_reparsed_utf16\": {}, \"structural\": [{}]}}",
            path,
            text.len(),
            utf16,
            stats(parse),
            all.len(),
            flatten_all,
            stats(window),
            window_nodes,
            stats(edit_only),
            stats(edit),
            stats(reparsed),
            structural.join(", ")
        );
    }
}
