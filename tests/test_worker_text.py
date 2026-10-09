"""Unit tests for the text helpers in Sources/worker.py.

Run: python3 -m unittest discover -s tests      (needs: pip install num2words)
"""
import importlib.util
import pathlib
import sys
import unittest

_path = pathlib.Path(__file__).resolve().parent.parent / "Sources" / "worker.py"
_spec = importlib.util.spec_from_file_location("worker", _path)
worker = importlib.util.module_from_spec(_spec)
_stdout = sys.stdout
_spec.loader.exec_module(worker)  # the worker redirects stdout to stderr on import
sys.stdout = _stdout


class PrepareUkrainianText(unittest.TestCase):
    def check(self, src, expected):
        self.assertEqual(worker.prepare_uk_text(src), expected)

    def test_years_take_the_right_case(self):
        self.check("У 2025 р. ми відкрились.", "У дві тисячі двадцять п'ятому році ми відкрились.")
        self.check("З 2020 року ціни зросли.", "З дві тисячі двадцятого року ціни зросли.")
        self.check("2003 рік був важким.", "дві тисячі третій рік був важким.")

    def test_units_agree_with_numbers(self):
        self.check("1 грн", "одна гривня")
        self.check("3 млн грн", "три мільйони гривень")
        self.check("21 грн", "двадцять одна гривня")
        self.check("5 хв", "п'ять хвилин")
        self.check("22 кг", "двадцять два кілограми")
        self.check("2,5%", "два кома п'ять відсотка")
        self.check("Знижка 15%!", "Знижка п'ятнадцять відсотків!")

    def test_sentence_end_dot_survives_abbreviation(self):
        self.check("Лише 11 хв. Далі буде.", "Лише одинадцять хвилин. Далі буде.")
        self.check("Ціна 40 дол. Це недорого.", "Ціна сорок доларів. Це недорого.")
        self.check("за 3 млн грн. Знижка", "за три мільйони гривень. Знижка")

    def test_abbreviations(self):
        self.check("м. Київ, вул. Хрещатик, № 5", "місто Київ, вулиця Хрещатик, номер 5")
        self.check("і т.д.", "і так далі.")
        self.check("т.д., т.п.", "так далі, тому подібне.")

    def test_russian_letters_are_fixed(self):
        self.check("однотонний оксамыт, оксамы́т і тюль", "однотонний оксамит, оксами́т і тюль")
        self.check("Эта обʼєкт", "Ета об'єкт")

    def test_spelling_tells_ukrainian_from_russian(self):
        self.assertEqual(worker.text_language_hint("Останнім часом ми все частіше отримуємо запити"), "uk")
        self.assertEqual(worker.text_language_hint("В последнее время мы всё чаще получаем запросы"), "ru")
        self.assertIsNone(worker.text_language_hint("Бархат"))

    def test_apostrophes_and_thousands(self):
        self.check("інтер’єр ʼємність", "інтер'єр ʼємність")
        self.check("12 500 диванів", "12500 диванів")
        self.check("виши́вка", "виши́вка")  # stress marks are kept for the model


class Segments(unittest.TestCase):
    def test_paragraphs_and_sentences(self):
        segs = worker.split_segments("Перше речення. Друге речення!\n\nНовий абзац.")
        self.assertEqual(segs, [("Перше речення. Друге речення!", True), ("Новий абзац.", True)])

    def test_long_sentence_is_split(self):
        text = ", ".join(["слово"] * 80) + "."
        segs = worker.split_segments(text, max_chars=160)
        self.assertTrue(all(len(s) <= 160 for s, _ in segs))
        self.assertEqual(" ".join(s for s, _ in segs).replace(" ", ""), text.replace(" ", ""))


    def test_lowercase_continues_the_sentence(self):
        segs = worker.split_segments("Це т. зв. приклад, напр. такий. Далі нове речення.", max_chars=40)
        self.assertEqual([s for s, _ in segs], ["Це т. зв. приклад, напр. такий.", "Далі нове речення."])

    def test_scripts_without_capital_letters(self):
        segs = worker.split_segments("هذه جملة أولى طويلة نسبيا. وهذه جملة ثانية طويلة أيضا.", max_chars=30)
        self.assertEqual(len(segs), 2)
        segs = worker.split_segments("今天天气很好。我们去公园散步吧！你觉得怎么样？", max_chars=30)
        self.assertEqual([s for s, _ in segs], ["今天天气很好。", "我们去公园散步吧！", "你觉得怎么样？"])

    def test_text_without_spaces_is_cut_hard(self):
        segs = worker.split_segments("あ" * 200, max_chars=90)
        self.assertTrue(all(worker._tlen(s) <= 90 for s, _ in segs))
        self.assertEqual("".join(s for s, _ in segs), "あ" * 200)
        segs = worker.split_segments("x" * 400, max_chars=160)
        self.assertTrue(all(len(s) <= 160 for s, _ in segs))
        self.assertEqual("".join(s for s, _ in segs), "x" * 400)


class Clarity(unittest.TestCase):
    def test_punctuation_and_apostrophes_ignored(self):
        self.assertEqual(worker.char_error_rate("Інтер’єр — це все!", "інтерʼєр це все"), 0.0)

    def test_stress_marks_ignored(self):
        self.assertEqual(worker.char_error_rate("Виши́вка та жака́рд", "вишивка та жакард"), 0.0)

    def test_errors_counted(self):
        self.assertAlmostEqual(worker.char_error_rate("абвг", "абвд"), 0.25)
        self.assertEqual(worker.char_error_rate("", ""), 0.0)


    def test_sound_tags_are_not_words(self):
        self.assertEqual(worker.char_error_rate("[laughter] Ну ти даєш! [sigh]", "ну ти даєш"), 0.0)


class UkrainianStress(unittest.TestCase):
    """Dictionary stress (needs: pip install --no-deps ukrainian-word-stress marisa-trie)."""

    def setUp(self):
        if worker._get_stressifier() is None:
            self.skipTest("ukrainian-word-stress is not installed")

    def test_known_words_get_their_stress(self):
        self.assertEqual(worker.stress_uk_text("Оксамит і вишивка."), "Оксами́т і ви́шивка.")

    def test_hand_placed_mark_wins(self):
        self.assertEqual(worker.stress_uk_text("виши́вка оксами́т"), "виши́вка оксами́т")
        self.assertEqual(worker.stress_uk_text("вишивка́"), "вишивка́")  # the user's choice, even if odd

    def test_heteronyms_and_tags_are_left_alone(self):
        self.assertEqual(worker.stress_uk_text("замок [laughter] Замок"), "замок [laughter] Замок")

    def test_misheard_words_are_found(self):
        odd = worker.unknown_uk_words("Останнім часом ми все чистише отримуємо з западові дизайни рифштор на класичні тканіни.")
        self.assertIn("рифштор", odd)
        self.assertIn("тканіни", odd)
        self.assertNotIn("часом", odd)
        self.assertEqual(worker.unknown_uk_words("Ця колекція для тих, хто працює з інтер'єром."), [])

    def test_notations(self):
        self.assertEqual(worker.encode_stress("ви́шивка", "upper"), "вИшивка")
        self.assertEqual(worker.encode_stress("ви́шивка", "plus"), "в+ишивка")
        self.assertEqual(worker.encode_stress("ви́шивка", "acute"), "ви´шивка")
        self.assertEqual(worker.encode_stress("ви́шивка", "none"), "вишивка")
        self.assertEqual(worker.encode_stress("ви́шивка", "combining"), "ви́шивка")

    def test_notations_are_invisible_to_the_clarity_check(self):
        for how in ("upper", "plus", "acute", "combining"):
            self.assertEqual(worker.char_error_rate(worker.encode_stress("Ви́шивка та жака́рд", how), "вишивка та жакард"), 0.0)


class VoiceStyle(unittest.TestCase):
    def test_neutral_style_changes_nothing(self):
        fx = worker.resolve_style(None)
        self.assertEqual((fx["melody"], fx["speed_mul"], fx["pitch"], fx["tone"], fx["pause_mul"], fx["gain_db"]),
                         (1.0, 1.0, 0.0, 0.0, 1.0, 0.0))
        self.assertEqual((fx["presence_db"], fx["compress"]), (0.0, 0.0))

    def test_controls_move_the_right_way(self):
        self.assertGreater(worker.resolve_style({"intonation": 1})["melody"], 1.5)
        self.assertLess(worker.resolve_style({"intonation": -1})["melody"], 0.5)
        lively, relaxed = worker.resolve_style({"energy": 1}), worker.resolve_style({"energy": -1})
        self.assertGreater(lively["speed_mul"], 1.0)
        self.assertLess(lively["pause_mul"], 1.0)
        self.assertLess(relaxed["speed_mul"], 1.0)
        self.assertGreater(relaxed["pause_mul"], 1.0)

    def test_values_are_clamped_and_junk_is_ignored(self):
        fx = worker.resolve_style({"intonation": 50, "pitch": -99, "pauses": 0, "volume": "loud", "tone": None})
        self.assertLessEqual(fx["melody"], 2.0)
        self.assertEqual(fx["pitch"], -6)
        self.assertGreaterEqual(fx["pause_mul"], 0.2)
        self.assertEqual((fx["gain_db"], fx["tone"]), (0.0, 0.0))

    def test_voice_design_tags(self):
        self.assertEqual(worker.clean_instruct("Female, low pitch, happy, british accent", "en"), "female, low pitch, british accent")
        self.assertEqual(worker.clean_instruct("female, british accent", "uk"), "female")  # accents are English-only
        self.assertEqual(worker.clean_instruct("male, female, elderly"), "male, elderly")   # one per group
        self.assertEqual(worker.clean_instruct("whisper"), "female, whisper")
        self.assertIsNone(worker.clean_instruct("happy, sad"))
        self.assertIsNone(worker.clean_instruct(""))


class AccentRemoval(unittest.TestCase):
    def test_bridge_phrase(self):
        self.assertIn("Привіт", worker.bridge_text("uk", "будь-що"))
        # no built-in phrase: the beginning of the text itself, without sound tags
        text = "Bu mətn Azərbaycan dilində yazılıb və kifayət qədər uzundur. [laughter] İkinci cümlə də burada, o da uzundur. Üçüncü."
        bridge = worker.bridge_text("az", text)
        self.assertTrue(bridge.startswith("Bu mətn"))
        self.assertNotIn("[", bridge)
        self.assertGreaterEqual(len(bridge), 90)
        self.assertIsNone(worker.bridge_text("az", "Salam!"))  # too short to learn from


class Messages(unittest.TestCase):
    def test_translation(self):
        worker._LANG = "ru"
        self.assertEqual(worker.T("Phrase {i} of {n}", i=1, n=3), "Фраза 1 из 3")
        worker._LANG = "en"
        self.assertEqual(worker.T("Phrase {i} of {n}", i=1, n=3), "Phrase 1 of 3")


if __name__ == "__main__":
    unittest.main()
