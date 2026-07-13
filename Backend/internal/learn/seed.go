package learn

import (
	"fmt"
	"log"
)

// dictionaryCategories maps every word of the 150-word model vocabulary
// (Inference_backend/TSL_Output/label_map.json) to a Thai category label
// for the dictionary view. Keep in sync when the vocabulary changes.
var dictionaryCategories = map[string][]string{
	"ตัวเลข": {
		"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "20", "30", "100",
	},
	"คำพื้นฐาน": {
		"ขอโทษ", "บ๊ายบาย", "ดี", "แย่", "เร็ว", "เอา",
	},
	"ผู้คนและครอบครัว": {
		"คุณ", "ฉัน", "ผม", "เรา", "พี่", "พ่อ", "แม่", "พ่อค้า",
	},
	"ร่างกาย": {
		"คิ้ว", "จมูก", "ตา", "นิ้ว", "ปาก", "มือ", "หู", "แก้ม",
	},
	"อาหารและเครื่องดื่ม": {
		"กล้วย", "กาแฟ", "กุ้ง", "ข้าว", "ชา", "นม", "น้ำ", "ปลา",
		"มะม่วง", "ส้ม", "เค้ก", "แตงโม", "แอปเปิ้ล", "ไก่ทอด", "ไข่",
	},
	"สัตว์และธรรมชาติ": {
		"กบ", "นก", "ปู", "ไก่", "ทราย", "ทะเล", "หิน", "ลม", "ฝนตก",
	},
	"สี": {
		"สี", "สีชมพู", "สีดำ", "สีฟ้า", "สีม่วง", "สีเขียว", "สีแดง",
	},
	"วันและเดือน": {
		"วันจันทร์", "วันอังคาร", "วันพุธ", "วันพฤหัสบดี", "วันศุกร์",
		"วันเสาร์", "วันอาทิตย์",
		"มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม", "มิถุนายน",
		"กรกฎาคม", "สิงหาคม", "กันยายน", "ตุลาคม", "พฤศจิกายน", "ธันวาคม",
	},
	"เวลา": {
		"วันนี้", "พรุ่งนี้", "เมื่อวาน", "เมื่อวานซืน", "เช้า", "ปี", "เดือน", "เวลา",
	},
	"อารมณ์ความรู้สึก": {
		"กังวล", "ง่วง", "ดีใจ", "หิว", "เกลียด", "เครียด", "เบื่อ",
		"ทะเลาะ", "คิด", "รัก",
	},
	"กิจวัตรและการกระทำ": {
		"กด", "กระโดด", "กิน", "ขับรถ", "ขาย", "ซื้อ", "ดื่ม", "ดู",
		"ทำงาน", "นอน", "นั่ง", "พูด", "ฟัง", "ยืน", "วิ่ง", "สอน",
		"อาบน้ำ", "อ่าน", "เขียน", "เดิน", "เปิด", "ปิด", "เรียน", "เล่น",
		"โทร", "ถ่ายรูป", "ล้าง", "แปรงฟัน", "ไป",
	},
	"สิ่งของและสถานที่": {
		"กระจก", "กระดาษ", "กุญแจ", "ตลาด", "ตู้เสื้อผ้า", "ถนน", "ถุงเท้า",
		"บ้าน", "ปากกา", "รองเท้า", "หนังสือ", "หมวก", "ห้องครัว", "เสื้อ",
		"แว่น", "โต๊ะ", "โรงเรียน", "สะพาน",
	},
}

// seedTopic is one starter roadmap topic with its exercise words, in
// roadmap order. defaultPassConfidence applies to every seeded exercise
// and stays editable per-exercise in the admin webui.
type seedTopic struct {
	slug  string
	title string
	icon  string
	words []string
}

const defaultPassConfidence = 0.8

var seedTopics = []seedTopic{
	{"basics", "คำพื้นฐานและทักทาย", "👋", []string{"ขอโทษ", "บ๊ายบาย", "ดี", "แย่", "เร็ว"}},
	{"people", "ผู้คนและครอบครัว", "👪", []string{"ฉัน", "คุณ", "พ่อ", "แม่", "พี่"}},
	{"food", "อาหารและเครื่องดื่ม", "🍚", []string{"กิน", "ดื่ม", "ข้าว", "น้ำ", "ไข่"}},
	{"numbers", "ตัวเลข", "🔢", []string{"1", "2", "3", "4", "5"}},
	{"colors", "สีสัน", "🎨", []string{"สีแดง", "สีเขียว", "สีฟ้า", "สีดำ", "สีชมพู"}},
	{"feelings", "อารมณ์ความรู้สึก", "😊", []string{"ดีใจ", "หิว", "ง่วง", "เครียด", "รัก"}},
	{"daily", "กิจวัตรประจำวัน", "🏃", []string{"นอน", "ทำงาน", "เรียน", "อ่าน", "เขียน"}},
	{"time", "วันและเวลา", "📅", []string{"วันนี้", "พรุ่งนี้", "เมื่อวาน", "เช้า", "เวลา"}},
}

// Seed populates the dictionary and, when no topics exist yet, the starter
// roadmap. Idempotent: signs insert with OR IGNORE, topics seed only once
// so admin edits are never overwritten.
func Seed(s *Store) error {
	for category, words := range dictionaryCategories {
		for _, w := range words {
			if _, err := s.db.Exec(
				`INSERT OR IGNORE INTO learn_signs (word, category) VALUES (?, ?)`,
				w, category); err != nil {
				return fmt.Errorf("seeding sign %q: %w", w, err)
			}
		}
	}

	var topicCount int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM learn_topics`).Scan(&topicCount); err != nil {
		return fmt.Errorf("counting topics: %w", err)
	}
	if topicCount > 0 {
		return nil
	}

	for i, st := range seedTopics {
		topic, err := s.CreateTopic(Topic{
			Slug: st.slug, Title: st.title, Icon: st.icon,
			SortOrder: i, Published: true,
		})
		if err != nil {
			return fmt.Errorf("seeding topic %q: %w", st.slug, err)
		}
		for j, w := range st.words {
			if _, err := s.CreateExercise(Exercise{
				TopicID: topic.ID, Word: w, SortOrder: j,
				PassConfidence: defaultPassConfidence, Published: true,
			}); err != nil {
				return fmt.Errorf("seeding exercise %q: %w", w, err)
			}
		}
	}
	log.Printf("learn: seeded %d topics with starter exercises", len(seedTopics))
	return nil
}
