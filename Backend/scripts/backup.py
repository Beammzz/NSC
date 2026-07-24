#!/usr/bin/env python3
"""
SignMind AI Backup Utility
Backs up the SQLite database and exports dictionary keypoint animation data.

Usage:
    python Backend/scripts/backup.py
"""

import os
import sys
import json
import sqlite3
from datetime import datetime

def run_backup():
    # Base directory resolution
    script_dir = os.path.dirname(os.path.abspath(__file__))
    backend_dir = os.path.abspath(os.path.join(script_dir, ".."))
    
    src_db_path = os.path.join(backend_dir, "data", "predictions.db")
    backup_dir = os.path.join(backend_dir, "data", "backups")
    os.makedirs(backup_dir, exist_ok=True)
    
    if not os.path.exists(src_db_path):
        print(f"Error: Database not found at {src_db_path}", file=sys.stderr)
        sys.exit(1)
        
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    print(f"Starting backup process at {datetime.now().isoformat()}...")
    print(f"Source DB: {src_db_path}")
    print(f"Backup Dir: {backup_dir}")

    # Connect to SQLite source
    src_conn = sqlite3.connect(src_db_path)

    # 1. Thread-safe SQLite Binary Backup
    timestamped_db = os.path.join(backup_dir, f"predictions_backup_{timestamp}.db")
    latest_db = os.path.join(backup_dir, "predictions_latest.db")

    print(f"[1/4] Performing SQLite binary backup -> predictions_backup_{timestamp}.db")
    dst_conn = sqlite3.connect(timestamped_db)
    src_conn.backup(dst_conn)
    dst_conn.close()

    latest_conn = sqlite3.connect(latest_db)
    src_conn.backup(latest_conn)
    latest_conn.close()

    # 2. Complete SQL Dump
    timestamped_sql = os.path.join(backup_dir, f"full_database_dump_{timestamp}.sql")
    latest_sql = os.path.join(backup_dir, "full_database_latest.sql")

    print(f"[2/4] Generating complete SQL dump -> full_database_dump_{timestamp}.sql")
    with open(timestamped_sql, "w", encoding="utf-8") as f:
        for line in src_conn.iterdump():
            f.write(f"{line}\n")
            
    with open(latest_sql, "w", encoding="utf-8") as f:
        for line in src_conn.iterdump():
            f.write(f"{line}\n")

    # 3. Export Dictionary Keypoint Animations (JSON)
    cur = src_conn.cursor()
    cur.execute("SELECT word, category, keypoint_frames FROM learn_signs WHERE keypoint_frames IS NOT NULL AND keypoint_frames != ''")
    rows = cur.fetchall()

    dict_keypoints = []
    sql_statements = [
        "-- SignMind AI Dictionary Keypoints Backup",
        f"-- Exported on: {datetime.now().isoformat()}",
        f"-- Total signs with animation: {len(rows)}",
        ""
    ]

    for word, category, raw_kp in rows:
        try:
            parsed_kp = json.loads(raw_kp)
        except Exception:
            parsed_kp = raw_kp

        dict_keypoints.append({
            "word": word,
            "category": category,
            "keypoint_frames": parsed_kp
        })

        escaped_word = word.replace("'", "''")
        escaped_cat = category.replace("'", "''") if category else ""
        escaped_kp = raw_kp.replace("'", "''")
        
        sql_stmt = (
            f"INSERT INTO learn_signs (word, category, keypoint_frames) "
            f"VALUES ('{escaped_word}', '{escaped_cat}', '{escaped_kp}') "
            f"ON CONFLICT(word) DO UPDATE SET "
            f"category=excluded.category, keypoint_frames=excluded.keypoint_frames;"
        )
        sql_statements.append(sql_stmt)

    timestamped_json = os.path.join(backup_dir, f"dictionary_keypoints_{timestamp}.json")
    latest_json = os.path.join(backup_dir, "dictionary_keypoints_latest.json")

    print(f"[3/4] Exporting {len(dict_keypoints)} keypoint animation entries -> dictionary_keypoints_{timestamp}.json")
    with open(timestamped_json, "w", encoding="utf-8") as f:
        json.dump(dict_keypoints, f, ensure_ascii=False, indent=2)
    with open(latest_json, "w", encoding="utf-8") as f:
        json.dump(dict_keypoints, f, ensure_ascii=False, indent=2)

    # 4. Export Dictionary Keypoints SQL Script
    timestamped_kp_sql = os.path.join(backup_dir, f"dictionary_keypoints_{timestamp}.sql")
    latest_kp_sql = os.path.join(backup_dir, "dictionary_keypoints_latest.sql")

    print(f"[4/4] Generating dictionary keypoint SQL seed script -> dictionary_keypoints_{timestamp}.sql")
    with open(timestamped_kp_sql, "w", encoding="utf-8") as f:
        f.write("\n".join(sql_statements))
    with open(latest_kp_sql, "w", encoding="utf-8") as f:
        f.write("\n".join(sql_statements))

    src_conn.close()
    
    print("\n[SUCCESS] Backup Completed Successfully!")
    print(f"Summary of artifacts created in {backup_dir}:")
    print(f"  - SQLite DB Backup: {os.path.basename(timestamped_db)}")
    print(f"  - Full SQL Dump:    {os.path.basename(timestamped_sql)}")
    print(f"  - Keypoints JSON:   {os.path.basename(timestamped_json)} ({len(dict_keypoints)} animated signs)")
    print(f"  - Keypoints SQL:    {os.path.basename(timestamped_kp_sql)}")

if __name__ == "__main__":
    run_backup()
