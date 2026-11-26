#!/usr/bin/env python3
"""Read the ERP export used by the fill-batch skill.

The export files are tab-separated text in GBK that carry an .XLS extension.
They contain a text column with batch, expiry and quantity:

    批号:E2506003 生产日期:2026-05-08 效期:2027-10-31 数量:-398

Subcommands:
    dump   <file> [--json OUT]      write every parsed row as JSON
    lookup <file> <customer> <keyword> [--qty N] [--top N]
                                     show candidate rows, newest first

Both subcommands print a short human summary; JSON goes to --json or stdout.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

INFO_RE = re.compile(
    r"批号:(?P<batch>.*?)\s*(?:生产日期:(?P<produced>\S*))?\s*(?:效期:(?P<expiry>\S*))?\s*数量:(?P<qty>-?\d+)"
)

# Header names seen in exports; the date column is called 发票日期 or 开单日期.
COLUMNS = {
    "biz": ("业务类型",),
    "date": ("发票日期", "开单日期", "单据日期"),
    "branch": ("分公司代码",),
    "code": ("商品代码",),
    "name": ("品名",),
    "spec": ("型号/规格", "规格"),
    "customer_code": ("客户代码",),
    "customer": ("客户名称",),
    "info": ("商品批号/效期",),
    "mfr": ("生产厂家",),
}


def decode(data: bytes) -> str:
    for encoding in ("gbk", "utf-8-sig", "utf-16"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("gbk", errors="replace")


def split_rows(text: str) -> list[list[str]]:
    return [line.split("\t") for line in text.splitlines() if line.strip()]


def column_index(header: list[str]) -> dict[str, int]:
    mapping: dict[str, int] = {}
    for key, names in COLUMNS.items():
        for index, cell in enumerate(header):
            if cell.strip() in names:
                mapping[key] = index
                break
    required = ("name", "customer", "info")
    missing = [key for key in required if key not in mapping]
    if missing:
        raise SystemExit(f"unrecognized header, missing columns: {missing}\nheader={header}")
    return mapping


def parse_rows(path: str) -> list[dict]:
    text = decode(open(path, "rb").read())
    rows = split_rows(text)
    if not rows:
        raise SystemExit(f"empty file: {path}")
    index = column_index(rows[0])
    records: list[dict] = []
    for row in rows[1:]:
        if len(row) <= max(index.values()):
            continue
        biz = row[index["biz"]].strip() if "biz" in index else ""
        if biz == "合计":
            continue
        info = row[index["info"]]
        match = INFO_RE.search(info)
        if not match:
            continue
        qty = int(match.group("qty"))
        records.append(
            {
                "date": row[index["date"]].strip() if "date" in index else "",
                "branch": row[index["branch"]].strip() if "branch" in index else "",
                "biz": biz,
                "code": row[index["code"]].strip() if "code" in index else "",
                "name": row[index["name"]].strip(),
                "spec": row[index["spec"]].strip() if "spec" in index else "",
                "customer": row[index["customer"]].strip(),
                "batch": match.group("batch").strip(),
                "produced": (match.group("produced") or "").strip(),
                "expiry": (match.group("expiry") or "").strip(),
                "qty": qty,
                "mfr": row[index["mfr"]].strip() if "mfr" in index else "",
            }
        )
    return records


def sort_key(record: dict) -> tuple[str, str]:
    raw = record["date"].replace("-", "/")
    date_part, _, time_part = raw.partition(" ")
    return date_part, time_part or "00:00:00"


def cmd_dump(args: argparse.Namespace) -> None:
    records = parse_rows(args.file)
    payload = json.dumps(records, ensure_ascii=False, indent=1)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            handle.write(payload)
        customers = sorted({record["customer"] for record in records})
        print(f"rows={len(records)} customers={len(customers)} json={args.json}")
        for customer in customers:
            count = sum(1 for record in records if record["customer"] == customer)
            print(f"  {count:5d}  {customer}")
    else:
        print(payload)


def cmd_lookup(args: argparse.Namespace) -> None:
    records = parse_rows(args.file)
    hits = [
        record
        for record in records
        if args.customer in record["customer"]
        and args.keyword in record["name"]
        and (args.qty is None or record["qty"] == args.qty)
    ]
    hits.sort(key=sort_key, reverse=True)
    print(f"customer={args.customer} keyword={args.keyword} qty={args.qty} hits={len(hits)}")
    for record in hits[: args.top]:
        print(
            "  {date} | 批号 {batch} | 效期 {expiry} | 数量 {qty} | {name} | {spec} | {mfr} | 分公司{branch}".format(
                **record
            )
        )
    same_day = [record for record in hits if args.qty is not None and record["qty"] == args.qty]
    if same_day:
        print(f"  qty-match newest: {sort_key(same_day[0])[0]} batch={same_day[0]['batch']}")
    if hits:
        print(f"  newest: {sort_key(hits[0])[0]} batch={hits[0]['batch']}")


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:  # pragma: no cover - very old Python
        pass
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    dump = sub.add_parser("dump", help="parse every row")
    dump.add_argument("file")
    dump.add_argument("--json", default=None)
    dump.set_defaults(func=cmd_dump)

    lookup = sub.add_parser("lookup", help="find candidate batches")
    lookup.add_argument("file")
    lookup.add_argument("customer")
    lookup.add_argument("keyword")
    lookup.add_argument("--qty", type=int, default=None)
    lookup.add_argument("--top", type=int, default=8)
    lookup.set_defaults(func=cmd_lookup)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
