#!/usr/bin/env python3
"""Отчёт по логу секундомера (time_log.csv).

Запуск:
    python3 report.py            # сводка за сегодня, неделю и по задачам
    python3 report.py --days 30  # разбивка по дням за последние 30 дней
"""

import argparse
import csv
from collections import defaultdict
from datetime import datetime, date, timedelta
from pathlib import Path

LOG_FILE = Path.home() / "Documents" / "time_log.csv"                  # как в таймере; иначе --log
INCOMPLETE_FILE = LOG_FILE.parent / "incomplete_sessions.csv"        # маркер «неполный день» из таймера, по сессиям


def human(seconds: int) -> str:
    h, m = seconds // 3600, (seconds % 3600) // 60
    if h:
        return f"{h} ч {m:02d} м"
    if m:
        return f"{m} м"
    return f"{seconds} с"


def load():
    rows = []
    if not LOG_FILE.exists():
        return rows
    with open(LOG_FILE, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                start = datetime.strptime(r["start"], "%Y-%m-%d %H:%M:%S")
                end = datetime.strptime(r["end"], "%Y-%m-%d %H:%M:%S")
                r["_date"] = start.date()
                r["_sec"] = int((end - start).total_seconds())   # длительность не хранится, считаем
                rows.append(r)
            except (ValueError, KeyError):
                continue
    return rows


def load_incomplete():
    """session_start сессий, отмеченных в таймере маркером «неполный день»."""
    if not INCOMPLETE_FILE.exists():
        return set()
    with open(INCOMPLETE_FILE, newline="", encoding="utf-8") as f:
        return {r["session_start"] for r in csv.DictReader(f) if r.get("session_start")}


def bar(seconds: int, scale: int) -> str:
    n = round(seconds / scale * 30) if scale else 0
    return "█" * n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", help="путь к time_log.csv (по умолчанию ~/Documents/time_log.csv)")
    ap.add_argument("--days", type=int, default=0,
                    help="показать разбивку по дням за N последних дней")
    args = ap.parse_args()
    global LOG_FILE, INCOMPLETE_FILE
    if args.log:
        LOG_FILE = Path(args.log).expanduser().resolve()
        INCOMPLETE_FILE = LOG_FILE.parent / "incomplete_sessions.csv"

    rows = load()
    if not rows:
        print(f"Лог пуст или не найден: {LOG_FILE}")
        return

    today = date.today()
    week_start = today - timedelta(days=today.weekday())

    today_sec = sum(r["_sec"] for r in rows if r["_date"] == today)
    week_sec = sum(r["_sec"] for r in rows if r["_date"] >= week_start)
    total_sec = sum(r["_sec"] for r in rows)

    print("=" * 44)
    print(f"  Сегодня:    {human(today_sec)}")
    print(f"  За неделю:  {human(week_sec)}")
    print(f"  Всего:      {human(total_sec)}  ({len(rows)} интервалов)")
    print("=" * 44)

    if args.days:
        per_day = defaultdict(int)
        for r in rows:
            if r["_date"] >= today - timedelta(days=args.days - 1):
                per_day[r["_date"]] += r["_sec"]
        if per_day:
            scale = max(per_day.values())
            inc_by_day = defaultdict(int)          # день сессии — по дате её session_start
            for s in load_incomplete() & {r["session_start"] for r in rows}:
                inc_by_day[datetime.strptime(s, "%Y-%m-%d %H:%M:%S").date()] += 1
            print(f"\nПо дням (последние {args.days}):")
            for d in sorted(per_day):
                mark = f"  · неполных сессий: {inc_by_day[d]}" if inc_by_day.get(d) else ""
                print(f"  {d:%a %d.%m}  {human(per_day[d]):>10}  {bar(per_day[d], scale)}{mark}")

    # Разбивка по задачам за текущую неделю
    per_task = defaultdict(int)
    for r in rows:
        if r["_date"] >= week_start:
            per_task[r.get("task", "—")] += r["_sec"]
    if per_task:
        scale = max(per_task.values())
        print("\nПо задачам (за неделю):")
        for task, sec in sorted(per_task.items(), key=lambda x: -x[1]):
            print(f"  {human(sec):>10}  {bar(sec, scale)} {task}")


if __name__ == "__main__":
    main()
