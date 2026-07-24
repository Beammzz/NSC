import sqlite3
import json
import os

db_path = r"Backend/data/predictions.db"
conn = sqlite3.connect(db_path)
cur = conn.cursor()

tables = cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
print("Tables in DB:")
for (tbl,) in tables:
    if tbl == 'sqlite_sequence':
        continue
    cur.execute(f"SELECT COUNT(*) FROM {tbl}")
    count = cur.fetchone()[0]
    print(f"  - {tbl}: {count} rows")

cur.execute("SELECT word, category, keypoint_frames FROM learn_signs WHERE keypoint_frames IS NOT NULL AND keypoint_frames != ''")
kp_rows = cur.fetchall()
print(f"\nTotal signs with keypoint_frames: {len(kp_rows)}")
for r in kp_rows[:5]:
    print(f"  Sample word: {r[0]}, category: {r[1]}, keypoint length: {len(r[2]) if r[2] else 0}")
