import sqlite3
import json
import os
from datetime import datetime

def perform_backup():
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    nsc_root = r"c:\Users\Sorra\VSCode\NSC"
    
    src_db_path = os.path.join(nsc_root, "Backend", "data", "predictions.db")
    backup_dir = os.path.join(nsc_root, "Backend", "data", "backups")
    os.makedirs(backup_dir, exist_ok=True)
    
    print(f"Reading from database: {src_db_path}")
    print(f"Saving backups to: {backup_dir}")
    
    if not os.path.exists(src_db_path):
        raise FileNotFoundError(f"Source database not found at {src_db_path}")

    src_conn = sqlite3.connect(src_db_path)

    # 1. SQLite Online Backup (.db file)
    backup_db_file = os.path.join(backup_dir, f"predictions_backup_{timestamp}.db")
    latest_db_file = os.path.join(backup_dir, "predictions_latest.db")

    print(f"Creating thread-safe SQLite backup: {backup_db_file}")
    dst_conn = sqlite3.connect(backup_db_file)
    src_conn.backup(dst_conn)
    dst_conn.close()

    latest_dst_conn = sqlite3.connect(latest_db_file)
    src_conn.backup(latest_dst_conn)
    latest_dst_conn.close()
    print("Database backup completed successfully.")

    # 2. Complete SQL Dump (.sql file)
    sql_dump_file = os.path.join(backup_dir, f"full_database_dump_{timestamp}.sql")
    sql_latest_file = os.path.join(backup_dir, "full_database_latest.sql")
    print(f"Creating full SQL dump: {sql_dump_file}")
    with open(sql_dump_file, "w", encoding="utf-8") as f:
        for line in src_conn.iterdump():
            f.write(f"{line}\n")
    with open(sql_latest_file, "w", encoding="utf-8") as f:
        for line in src_conn.iterdump():
            f.write(f"{line}\n")

    # 3. Export Dictionary Keypoint Animations (JSON & SQL)
    cur = src_conn.cursor()
    cur.execute("SELECT word, category, keypoint_frames FROM learn_signs WHERE keypoint_frames IS NOT NULL AND keypoint_frames != ''")
    rows = cur.fetchall()

    dictionary_keypoints = []
    sql_statements = [
        "-- Dictionary Keypoint Animations Backup",
        f"-- Generated at: {timestamp}",
        "-- Total signs: " + str(len(rows)),
        ""
    ]

    for word, category, keypoint_frames_raw in rows:
        try:
            kp_parsed = json.loads(keypoint_frames_raw)
        except Exception:
            kp_parsed = keypoint_frames_raw

        dictionary_keypoints.append({
            "word": word,
            "category": category,
            "keypoint_frames": kp_parsed
        })

        escaped_word = word.replace("'", "''")
        escaped_cat = category.replace("'", "''") if category else ""
        escaped_kp = keypoint_frames_raw.replace("'", "''")
        
        sql_stmt = (
            f"INSERT INTO learn_signs (word, category, keypoint_frames) "
            f"VALUES ('{escaped_word}', '{escaped_cat}', '{escaped_kp}') "
            f"ON CONFLICT(word) DO UPDATE SET "
            f"category=excluded.category, keypoint_frames=excluded.keypoint_frames;"
        )
        sql_statements.append(sql_stmt)

    json_backup_file = os.path.join(backup_dir, f"dictionary_keypoints_{timestamp}.json")
    json_latest_file = os.path.join(backup_dir, "dictionary_keypoints_latest.json")
    sql_kp_file = os.path.join(backup_dir, f"dictionary_keypoints_{timestamp}.sql")
    sql_kp_latest = os.path.join(backup_dir, "dictionary_keypoints_latest.sql")

    print(f"Exporting {len(dictionary_keypoints)} dictionary keypoint animations to JSON...")
    with open(json_backup_file, "w", encoding="utf-8") as f:
        json.dump(dictionary_keypoints, f, ensure_ascii=False, indent=2)

    with open(json_latest_file, "w", encoding="utf-8") as f:
        json.dump(dictionary_keypoints, f, ensure_ascii=False, indent=2)

    print(f"Exporting dictionary keypoint animations to SQL script...")
    with open(sql_kp_file, "w", encoding="utf-8") as f:
        f.write("\n".join(sql_statements))

    with open(sql_kp_latest, "w", encoding="utf-8") as f:
        f.write("\n".join(sql_statements))

    src_conn.close()

    print("\n--- BACKUP SUMMARY ---")
    print(f"1. Database file backup: {backup_db_file}")
    print(f"2. Database SQL dump: {sql_dump_file}")
    print(f"3. Dictionary keypoints JSON: {json_backup_file} ({len(dictionary_keypoints)} signs)")
    print(f"4. Dictionary keypoints SQL: {sql_kp_file}")
    print("All backup tasks finished successfully!")

if __name__ == "__main__":
    perform_backup()
