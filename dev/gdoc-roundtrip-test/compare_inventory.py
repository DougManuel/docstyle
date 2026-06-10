#!/usr/bin/env python3
"""Compare two DOCX inventory files and report what survived a round-trip.

Usage: python3 compare_inventory.py <before.json> <after.json> [report.json]

Produces a human-readable report on stdout and optionally a structured JSON report.
"""

import json
import sys


def verdict(before_count, after_count):
    """Return a verdict string based on counts."""
    if before_count == 0 and after_count == 0:
        return "N/A"
    if after_count == 0:
        return "LOST"
    if after_count == before_count:
        return "SURVIVED"
    if after_count < before_count:
        return "PARTIAL"
    return "CHANGED"  # more items after than before


def compare_field_codes(before, after):
    """Compare field codes by type."""
    b_types = {}
    for fc in before:
        t = fc["type"]
        b_types[t] = b_types.get(t, 0) + 1

    a_types = {}
    for fc in after:
        t = fc["type"]
        a_types[t] = a_types.get(t, 0) + 1

    all_types = sorted(set(list(b_types.keys()) + list(a_types.keys())))
    results = {}
    for t in all_types:
        bc = b_types.get(t, 0)
        ac = a_types.get(t, 0)
        results[t] = {
            "before": bc,
            "after": ac,
            "verdict": verdict(bc, ac),
        }

    # Check if Zotero citation content survived (not just count)
    b_zotero = [fc["instruction"] for fc in before if fc["type"] == "zotero_citation"]
    a_zotero = [fc["instruction"] for fc in after if fc["type"] == "zotero_citation"]
    content_match = None
    if b_zotero and a_zotero:
        if len(b_zotero) == len(a_zotero):
            matches = sum(1 for b, a in zip(b_zotero, a_zotero) if b.strip() == a.strip())
            content_match = f"{matches}/{len(b_zotero)} instructions match exactly"
        else:
            content_match = f"count mismatch: {len(b_zotero)} before, {len(a_zotero)} after"

    return {
        "by_type": results,
        "total_before": len(before),
        "total_after": len(after),
        "verdict": verdict(len(before), len(after)),
        "zotero_content_match": content_match,
    }


def compare_comments(before, after):
    """Compare comments by content."""
    b_texts = {c["id"]: c["text"] for c in before}
    a_texts = {c["id"]: c["text"] for c in after}

    # Try matching by text content since IDs may change
    b_text_set = set(b_texts.values())
    a_text_set = set(a_texts.values())
    matched = b_text_set & a_text_set
    lost = b_text_set - a_text_set
    new = a_text_set - b_text_set

    return {
        "before": len(before),
        "after": len(after),
        "matched_by_text": len(matched),
        "lost_texts": sorted(lost),
        "new_texts": sorted(new),
        "verdict": verdict(len(before), len(after)),
        "id_preserved": set(b_texts.keys()) == set(a_texts.keys()) if before and after else None,
    }


def compare_tracked_changes(before, after):
    """Compare tracked changes."""
    b_ins = [c for c in before if c["type"] == "insertion"]
    b_del = [c for c in before if c["type"] == "deletion"]
    a_ins = [c for c in after if c["type"] == "insertion"]
    a_del = [c for c in after if c["type"] == "deletion"]

    return {
        "insertions": {
            "before": len(b_ins),
            "after": len(a_ins),
            "verdict": verdict(len(b_ins), len(a_ins)),
        },
        "deletions": {
            "before": len(b_del),
            "after": len(a_del),
            "verdict": verdict(len(b_del), len(a_del)),
        },
        "verdict": verdict(len(before), len(after)),
    }


def compare_bookmarks(before, after):
    """Compare bookmarks by name."""
    b_names = {bm["name"] for bm in before}
    a_names = {bm["name"] for bm in after}
    survived = b_names & a_names
    lost = b_names - a_names
    new = a_names - b_names

    return {
        "before": len(before),
        "after": len(after),
        "survived_names": sorted(survived),
        "lost_names": sorted(lost),
        "new_names": sorted(new)[:20],  # cap output
        "verdict": verdict(len(b_names), len(a_names & b_names)),
    }


def compare_styles(before, after):
    """Compare style definitions."""
    b_ids = {s["id"] for s in before}
    a_ids = {s["id"] for s in after}
    survived = b_ids & a_ids
    lost = b_ids - a_ids
    new = a_ids - b_ids

    return {
        "before": len(before),
        "after": len(after),
        "survived": len(survived),
        "lost_ids": sorted(lost)[:30],
        "new_ids": sorted(new)[:30],
        "verdict": verdict(len(b_ids), len(survived)),
    }


def compare_zip_contents(before, after):
    """Compare zip file listings."""
    b_set = set(before)
    a_set = set(after)
    return {
        "before": len(before),
        "after": len(after),
        "lost_files": sorted(b_set - a_set),
        "new_files": sorted(a_set - b_set),
    }


def compare_inventories(before, after):
    """Compare two inventory dicts and produce a report."""
    report = {
        "before_source": before.get("source", "?"),
        "after_source": after.get("source", "?"),
        "zip_contents": compare_zip_contents(
            before.get("zip_contents", []),
            after.get("zip_contents", []),
        ),
        "field_codes": compare_field_codes(
            before.get("field_codes", []),
            after.get("field_codes", []),
        ),
        "comments": compare_comments(
            before.get("comments", []),
            after.get("comments", []),
        ),
        "tracked_changes": compare_tracked_changes(
            before.get("tracked_changes", []),
            after.get("tracked_changes", []),
        ),
        "bookmarks": compare_bookmarks(
            before.get("bookmarks", []),
            after.get("bookmarks", []),
        ),
        "styles": compare_styles(
            before.get("styles", []),
            after.get("styles", []),
        ),
        "footnotes": {
            "before": len(before.get("footnotes", [])),
            "after": len(after.get("footnotes", [])),
            "verdict": verdict(
                len(before.get("footnotes", [])),
                len(after.get("footnotes", [])),
            ),
        },
        "sections": {
            "before": len(before.get("sections", [])),
            "after": len(after.get("sections", [])),
            "verdict": verdict(
                len(before.get("sections", [])),
                len(after.get("sections", [])),
            ),
        },
    }

    return report


def print_report(report):
    """Print a human-readable summary."""
    print("=" * 70)
    print("GOOGLE DOCS ROUND-TRIP SURVIVAL REPORT")
    print("=" * 70)
    print(f"Before: {report['before_source']}")
    print(f"After:  {report['after_source']}")
    print()

    # Zip contents
    zc = report["zip_contents"]
    print(f"ZIP CONTENTS: {zc['before']} → {zc['after']} files")
    if zc["lost_files"]:
        print(f"  Lost:  {', '.join(zc['lost_files'][:10])}")
    if zc["new_files"]:
        print(f"  New:   {', '.join(zc['new_files'][:10])}")
    print()

    # Field codes
    fc = report["field_codes"]
    print(f"FIELD CODES: {fc['total_before']} → {fc['total_after']}  [{fc['verdict']}]")
    for t, info in fc["by_type"].items():
        marker = "✓" if info["verdict"] == "SURVIVED" else "✗" if info["verdict"] == "LOST" else "~"
        print(f"  {marker} {t}: {info['before']} → {info['after']}  [{info['verdict']}]")
    if fc["zotero_content_match"]:
        print(f"  Zotero content: {fc['zotero_content_match']}")
    print()

    # Comments
    cm = report["comments"]
    print(f"COMMENTS: {cm['before']} → {cm['after']}  [{cm['verdict']}]")
    if cm["lost_texts"]:
        for t in cm["lost_texts"][:5]:
            print(f"  Lost: \"{t[:80]}\"")
    if cm["id_preserved"] is not None:
        print(f"  IDs preserved: {cm['id_preserved']}")
    print()

    # Tracked changes
    tc = report["tracked_changes"]
    ins = tc["insertions"]
    dels = tc["deletions"]
    print(f"TRACKED CHANGES: [{tc['verdict']}]")
    print(f"  Insertions: {ins['before']} → {ins['after']}  [{ins['verdict']}]")
    print(f"  Deletions:  {dels['before']} → {dels['after']}  [{dels['verdict']}]")
    print()

    # Bookmarks
    bm = report["bookmarks"]
    print(f"BOOKMARKS: {bm['before']} → {bm['after']}  [{bm['verdict']}]")
    if bm["lost_names"]:
        print(f"  Lost: {', '.join(bm['lost_names'][:10])}")
    print()

    # Styles
    st = report["styles"]
    print(f"STYLES: {st['before']} → {st['after']}  (survived: {st['survived']})  [{st['verdict']}]")
    if st["lost_ids"]:
        print(f"  Lost: {', '.join(st['lost_ids'][:10])}")
    print()

    # Footnotes & Sections
    fn = report["footnotes"]
    sc = report["sections"]
    print(f"FOOTNOTES: {fn['before']} → {fn['after']}  [{fn['verdict']}]")
    print(f"SECTIONS:  {sc['before']} → {sc['after']}  [{sc['verdict']}]")
    print()

    # Overall verdict
    print("=" * 70)
    verdicts = [
        ("Field codes", fc["verdict"]),
        ("Comments", cm["verdict"]),
        ("Tracked changes", tc["verdict"]),
        ("Bookmarks", bm["verdict"]),
        ("Styles", st["verdict"]),
        ("Footnotes", fn["verdict"]),
        ("Sections", sc["verdict"]),
    ]
    print("SUMMARY:")
    for name, v in verdicts:
        icon = {"SURVIVED": "✓", "LOST": "✗", "PARTIAL": "~", "N/A": "-", "CHANGED": "?"}.get(v, "?")
        print(f"  {icon} {name}: {v}")
    print("=" * 70)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        before = json.load(f)
    with open(sys.argv[2]) as f:
        after = json.load(f)

    report = compare_inventories(before, after)
    print_report(report)

    if len(sys.argv) >= 4:
        with open(sys.argv[3], "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nStructured report written to: {sys.argv[3]}")


if __name__ == "__main__":
    main()
