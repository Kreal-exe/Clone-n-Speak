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


class Clarity(unittest.TestCase):
    def test_punctuation_and_apostrophes_ignored(self):
        self.assertEqual(worker.char_error_rate("Інтер’єр — це все!", "інтерʼєр це все"), 0.0)

    def test_stress_marks_ignored(self):
        self.assertEqual(worker.char_error_rate("Виши́вка та жака́рд", "вишивка та жакард"), 0.0)

    def test_errors_counted(self):
        self.assertAlmostEqual(worker.char_error_rate("абвг", "абвд"), 0.25)
        self.assertEqual(worker.char_error_rate("", ""), 0.0)


class Messages(unittest.TestCase):
    def test_translation(self):
        worker._LANG = "ru"
        self.assertEqual(worker.T("Phrase {i} of {n}", i=1, n=3), "Фраза 1 из 3")
        worker._LANG = "en"
        self.assertEqual(worker.T("Phrase {i} of {n}", i=1, n=3), "Phrase 1 of 3")


if __name__ == "__main__":
    unittest.main()
