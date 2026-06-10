#!/usr/bin/env python3
"""Extract a detailed XML inventory from a DOCX file for round-trip comparison.

Usage: python3 extract_inventory.py <input.docx> [output.json]

If output.json is omitted, writes to <input-stem>-inventory.json in the same directory.
"""

import json
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

WML = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
W14 = "http://schemas.microsoft.com/office/word/2010/wordml"
W15 = "http://schemas.microsoft.com/office/word/2012/wordml"
W16 = "http://schemas.microsoft.com/office/word/2018/wordml/cex"

NS = {
    "w": WML,
    "r": REL,
    "w14": W14,
    "w15": W15,
    "w16cex": W16,
}


def tag(ns_prefix, local):
    return f"{{{NS[ns_prefix]}}}{local}"


def wtag(local):
    return tag("w", local)


def get_text(elem):
    """Recursively get all text content from an element."""
    parts = []
    for t in elem.iter(wtag("t")):
        if t.text:
            parts.append(t.text)
    return "".join(parts)


def parse_xml_safe(path):
    """Parse XML file, returning None if it doesn't exist."""
    if not os.path.exists(path):
        return None
    return ET.parse(path).getroot()


def extract_field_codes(root):
    """Extract all field code sequences from document.xml.

    Walks the document looking for fldChar begin/separate/end sequences
    and collects the instrText between begin and separate.
    """
    fields = []
    current_instr = []
    in_field = False
    field_content = []
    depth = 0

    for elem in root.iter():
        if elem.tag == wtag("fldChar"):
            fld_type = elem.get(f"{{{WML}}}fldCharType") or elem.get("fldCharType") or ""
            if fld_type == "begin":
                depth += 1
                if depth == 1:
                    in_field = True
                    current_instr = []
                    field_content = []
            elif fld_type == "separate":
                if depth == 1:
                    pass  # instrText collection done
            elif fld_type == "end":
                if depth == 1 and in_field:
                    instr_text = "".join(current_instr).strip()
                    fields.append({
                        "instruction": instr_text,
                        "type": classify_field(instr_text),
                    })
                    in_field = False
                depth = max(0, depth - 1)
        elif elem.tag == wtag("instrText") and in_field and depth == 1:
            if elem.text:
                current_instr.append(elem.text)

    return fields


def classify_field(instr):
    """Classify a field code instruction into a category."""
    instr_upper = instr.upper().strip()
    if "ADDIN ZOTERO_ITEM" in instr_upper:
        return "zotero_citation"
    if "ADDIN ZOTERO_BIBL" in instr_upper:
        return "zotero_bibliography"
    if "ADDIN DOCSTYLE" in instr_upper:
        return "docstyle_marker"
    if instr_upper.startswith("TOC"):
        return "toc"
    if instr_upper.startswith("PAGE"):
        return "page_number"
    if instr_upper.startswith("NUMPAGES"):
        return "num_pages"
    if instr_upper.startswith("SECTIONPAGES"):
        return "section_pages"
    if instr_upper.startswith("HYPERLINK"):
        return "hyperlink"
    if instr_upper.startswith("REF"):
        return "cross_reference"
    if instr_upper.startswith("SEQ"):
        return "sequence"
    return "other"


def extract_comments(word_dir):
    """Extract comments from word/comments.xml."""
    comments = []
    root = parse_xml_safe(os.path.join(word_dir, "comments.xml"))
    if root is None:
        return comments

    for comment in root.iter(wtag("comment")):
        comment_id = comment.get(f"{{{WML}}}id") or comment.get("id") or ""
        author = comment.get(f"{{{WML}}}author") or comment.get("author") or ""
        date = comment.get(f"{{{WML}}}date") or comment.get("date") or ""
        text = get_text(comment)
        comments.append({
            "id": comment_id,
            "author": author,
            "date": date,
            "text": text,
        })

    return comments


def extract_comment_ranges(root):
    """Extract comment range markers from document.xml."""
    ranges = []
    for start in root.iter(wtag("commentRangeStart")):
        cid = start.get(f"{{{WML}}}id") or start.get("id") or ""
        ranges.append({"id": cid, "type": "start"})
    for end in root.iter(wtag("commentRangeEnd")):
        cid = end.get(f"{{{WML}}}id") or end.get("id") or ""
        ranges.append({"id": cid, "type": "end"})
    return ranges


def extract_tracked_changes(root):
    """Extract tracked changes (insertions and deletions) from document.xml."""
    changes = []
    for ins in root.iter(wtag("ins")):
        author = ins.get(f"{{{WML}}}author") or ins.get("author") or ""
        date = ins.get(f"{{{WML}}}date") or ins.get("date") or ""
        text = get_text(ins)
        changes.append({
            "type": "insertion",
            "author": author,
            "date": date,
            "text": text,
        })
    for dele in root.iter(wtag("del")):
        author = dele.get(f"{{{WML}}}author") or dele.get("author") or ""
        date = dele.get(f"{{{WML}}}date") or dele.get("date") or ""
        # For deletions, get delText
        parts = []
        for dt in dele.iter(wtag("delText")):
            if dt.text:
                parts.append(dt.text)
        text = "".join(parts)
        changes.append({
            "type": "deletion",
            "author": author,
            "date": date,
            "text": text,
        })
    return changes


def extract_bookmarks(root):
    """Extract bookmarks from document.xml."""
    bookmarks = []
    for bm in root.iter(wtag("bookmarkStart")):
        bm_id = bm.get(f"{{{WML}}}id") or bm.get("id") or ""
        name = bm.get(f"{{{WML}}}name") or bm.get("name") or ""
        bookmarks.append({"id": bm_id, "name": name})
    return bookmarks


def extract_styles(word_dir):
    """Extract style definitions from word/styles.xml."""
    styles = []
    root = parse_xml_safe(os.path.join(word_dir, "styles.xml"))
    if root is None:
        return styles

    for style in root.iter(wtag("style")):
        style_id = style.get(f"{{{WML}}}styleId") or style.get("styleId") or ""
        style_type = style.get(f"{{{WML}}}type") or style.get("type") or ""
        name_elem = style.find(wtag("name"))
        name = ""
        if name_elem is not None:
            name = name_elem.get(f"{{{WML}}}val") or name_elem.get("val") or ""
        based_on_elem = style.find(wtag("basedOn"))
        based_on = ""
        if based_on_elem is not None:
            based_on = based_on_elem.get(f"{{{WML}}}val") or based_on_elem.get("val") or ""
        styles.append({
            "id": style_id,
            "type": style_type,
            "name": name,
            "based_on": based_on,
        })

    return styles


def extract_content_controls(root):
    """Extract structured document tags (content controls) from document.xml."""
    sdts = []
    for sdt in root.iter(wtag("sdt")):
        props = sdt.find(wtag("sdtPr"))
        alias = ""
        tag_val = ""
        if props is not None:
            alias_elem = props.find(wtag("alias"))
            if alias_elem is not None:
                alias = alias_elem.get(f"{{{WML}}}val") or alias_elem.get("val") or ""
            tag_elem = props.find(wtag("tag"))
            if tag_elem is not None:
                tag_val = tag_elem.get(f"{{{WML}}}val") or tag_elem.get("val") or ""
        text = get_text(sdt)
        sdts.append({
            "alias": alias,
            "tag": tag_val,
            "text_preview": text[:200],
        })
    return sdts


def extract_footnotes(word_dir):
    """Extract footnotes from word/footnotes.xml."""
    footnotes = []
    root = parse_xml_safe(os.path.join(word_dir, "footnotes.xml"))
    if root is None:
        return footnotes

    for fn in root.iter(wtag("footnote")):
        fn_id = fn.get(f"{{{WML}}}id") or fn.get("id") or ""
        fn_type = fn.get(f"{{{WML}}}type") or fn.get("type") or ""
        if fn_type in ("separator", "continuationSeparator"):
            continue
        text = get_text(fn)
        footnotes.append({"id": fn_id, "text": text})

    return footnotes


def extract_sections(root):
    """Extract section properties from document.xml."""
    sections = []
    for sectPr in root.iter(wtag("sectPr")):
        section = {}
        pgSz = sectPr.find(wtag("pgSz"))
        if pgSz is not None:
            section["page_width"] = pgSz.get(f"{{{WML}}}w") or pgSz.get("w") or ""
            section["page_height"] = pgSz.get(f"{{{WML}}}h") or pgSz.get("h") or ""
            section["orient"] = pgSz.get(f"{{{WML}}}orient") or pgSz.get("orient") or "portrait"
        pgMar = sectPr.find(wtag("pgMar"))
        if pgMar is not None:
            for attr in ("top", "right", "bottom", "left", "header", "footer"):
                section[f"margin_{attr}"] = pgMar.get(f"{{{WML}}}{attr}") or pgMar.get(attr) or ""
        sections.append(section)
    return sections


def list_zip_contents(docx_path):
    """List all files inside the DOCX zip."""
    with zipfile.ZipFile(docx_path, "r") as z:
        return sorted(z.namelist())


def extract_inventory(docx_path):
    """Extract a complete inventory from a DOCX file."""
    with tempfile.TemporaryDirectory() as tmpdir:
        with zipfile.ZipFile(docx_path, "r") as z:
            z.extractall(tmpdir)

        word_dir = os.path.join(tmpdir, "word")
        doc_xml = os.path.join(word_dir, "document.xml")

        if not os.path.exists(doc_xml):
            print(f"ERROR: No word/document.xml found in {docx_path}", file=sys.stderr)
            sys.exit(1)

        root = ET.parse(doc_xml).getroot()

        inventory = {
            "source": os.path.basename(docx_path),
            "zip_contents": list_zip_contents(docx_path),
            "field_codes": extract_field_codes(root),
            "comments": extract_comments(word_dir),
            "comment_ranges": extract_comment_ranges(root),
            "tracked_changes": extract_tracked_changes(root),
            "bookmarks": extract_bookmarks(root),
            "styles": extract_styles(word_dir),
            "content_controls": extract_content_controls(root),
            "footnotes": extract_footnotes(word_dir),
            "sections": extract_sections(root),
        }

        # Summary counts
        inventory["summary"] = {
            "zip_files": len(inventory["zip_contents"]),
            "field_codes": len(inventory["field_codes"]),
            "field_code_types": {},
            "comments": len(inventory["comments"]),
            "comment_ranges": len([r for r in inventory["comment_ranges"] if r["type"] == "start"]),
            "tracked_changes_ins": len([c for c in inventory["tracked_changes"] if c["type"] == "insertion"]),
            "tracked_changes_del": len([c for c in inventory["tracked_changes"] if c["type"] == "deletion"]),
            "bookmarks": len(inventory["bookmarks"]),
            "styles": len(inventory["styles"]),
            "content_controls": len(inventory["content_controls"]),
            "footnotes": len(inventory["footnotes"]),
            "sections": len(inventory["sections"]),
        }

        for fc in inventory["field_codes"]:
            t = fc["type"]
            inventory["summary"]["field_code_types"][t] = inventory["summary"]["field_code_types"].get(t, 0) + 1

    return inventory


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    docx_path = sys.argv[1]
    if not os.path.exists(docx_path):
        print(f"ERROR: File not found: {docx_path}", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) >= 3:
        output_path = sys.argv[2]
    else:
        stem = os.path.splitext(os.path.basename(docx_path))[0]
        output_path = os.path.join(os.path.dirname(docx_path) or ".", f"{stem}-inventory.json")

    inventory = extract_inventory(docx_path)

    with open(output_path, "w") as f:
        json.dump(inventory, f, indent=2)

    # Print summary
    s = inventory["summary"]
    print(f"Inventory extracted: {docx_path}")
    print(f"  Zip files:          {s['zip_files']}")
    print(f"  Field codes:        {s['field_codes']}  {s['field_code_types']}")
    print(f"  Comments:           {s['comments']}")
    print(f"  Comment ranges:     {s['comment_ranges']}")
    print(f"  Tracked insertions: {s['tracked_changes_ins']}")
    print(f"  Tracked deletions:  {s['tracked_changes_del']}")
    print(f"  Bookmarks:          {s['bookmarks']}")
    print(f"  Styles:             {s['styles']}")
    print(f"  Content controls:   {s['content_controls']}")
    print(f"  Footnotes:          {s['footnotes']}")
    print(f"  Sections:           {s['sections']}")
    print(f"\nWritten to: {output_path}")


if __name__ == "__main__":
    main()
