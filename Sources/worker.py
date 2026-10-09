#!/usr/bin/env python3
"""Clone'n'Speak worker — OmniVoice on Apple MLX.

Long-lived process driven by the macOS app over stdin/stdout.
Requests and events are JSON objects, one per line. stdout is reserved for the
protocol: anything libraries print is redirected to stderr (the app's log).

Requests:  {"id": 1, "cmd": "synth", ...}
Events:    {"event": "status"|"progress"|"memory"|"result"|"error"|"ready", ...}

Voice controls (see resolve_style): the model itself has no "emotion" switch, so intonation, energy,
pitch, tone and pauses are built from what it does have — sampling temperature, guidance, speaking rate —
plus light DSP on the finished take. Voice design tags (gender, age, pitch, whisper, accent) apply to the
model's own voice only: with a cloned voice the sample decides.

Memory strategy (the whole point on 8 GB Macs):
  * the model is converted once into a 4/8-bit MLX checkpoint ("optimized") and loaded from there,
  * text is spoken sentence by sentence, so activations stay small whatever the text length,
  * MLX's buffer cache is capped, Whisper and the synthesizer are never resident together
    in low-memory mode.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import time
import traceback
import unicodedata
import wave

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

_proto = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1, encoding="utf-8")
sys.stdout = sys.stderr  # keep library prints off the protocol channel

_current_id = None
SR = 24000


def emit(event, **data):
    data["event"] = event
    if _current_id is not None and "id" not in data:
        data["id"] = _current_id
    _proto.write(json.dumps(data, ensure_ascii=False) + "\n")
    _proto.flush()


def status(msg):
    emit("status", msg=msg)


# --------------------------------------------------------------------------
# UI messages (the app passes its interface language in OV_LANG)
# --------------------------------------------------------------------------
_LANG = os.environ.get("OV_LANG", "en")
_RU = {
    "Optimizing the model for this Mac ({bits})…": "Оптимизирую модель под этот Mac ({bits})…",
    "Merging the LoRA adapter…": "Вливаю LoRA-адаптер…",
    "Loading the voice model · {bits}-bit…": "Загрузка модели голоса · {bits} бит…",
    "Loading Whisper · {bits}-bit…": "Загрузка Whisper · {bits} бит…",
    "Model loaded in {sec} s": "Модель загружена за {sec} с",
    "Speech recognition model (Whisper) is not installed. Download it on the Models page.": "Модель распознавания (Whisper) не установлена. Скачайте её на странице «Модели».",
    "Loading Whisper…": "Загрузка Whisper…",
    "Transcribing the voice sample…": "Распознаю речь в образце…",
    "Voice sample not found: {path}": "Файл образца не найден: {path}",
    "Creating the voice profile…": "Создаю голосовой профиль…",
    "The text is empty": "Текст для озвучки пустой",
    "Generating speech…": "Генерирую речь…",
    "Phrase {i} of {n}": "Фраза {i} из {n}",
    " · attempt {a}": " · попытка {a}",
    ": speaking…": ": озвучиваю…",
    "Checking clarity of {n} phrases…": "Проверяю разборчивость {n} фраз…",
    "Unexpected audio shape: {shape}": "Неожиданная форма аудио: {shape}",
    "Unknown command: {cmd}": "Неизвестная команда: {cmd}",
    " — not enough memory: close other apps or choose 4-bit precision.": " — не хватает памяти: закройте другие приложения или выберите точность 4 бита.",
    "This voice needs to be re-created: its sample or text is missing.": "Голос нужно пересоздать: нет образца или его текста.",
    "Detecting the language of the sample…": "Определяю язык образца…",
    "The sample is long — keeping its best {sec} seconds…": "Образец длинный — оставляю лучшие {sec} с…",
    "Teaching the voice {lang} pronunciation (once per voice)…": "Учу голос произношению: {lang} (один раз для голоса)…",
    "Teaching the voice {lang} pronunciation: take {i} of {n}…": "Учу голос произношению: {lang} — дубль {i} из {n}…",
    "Choosing the take with the cleanest pronunciation…": "Выбираю дубль с самым чистым произношением…",
    "Choosing the take that sounds most like you…": "Выбираю дубль, который больше всего похож на вас…",
    "Ukrainian or Russian? Transcribing both…": "Украинский или русский? Распознаю оба варианта…",
    " · take {a} of {b}": " · дубль {a} из {b}",
    "Choosing the best take of each phrase…": "Выбираю лучший дубль каждой фразы…",
}


def T(text, **kw):
    if _LANG == "ru":
        text = _RU.get(text, text)
    return text.format(**kw) if kw else text


# --------------------------------------------------------------------------
# Ukrainian text preparation
# --------------------------------------------------------------------------
_APOSTROPHES = "’ʼ`´‘′"

# Unit abbreviations after a number: (forms for 1 / 2-4 / 5+, feminine?)
_UK_UNITS = [  # (pattern, forms for 1 / 2-4 / 5+ / fractions, feminine?)
    (r"грн\.?", ("гривня", "гривні", "гривень", "гривні"), True),
    (r"коп\.", ("копійка", "копійки", "копійок", "копійки"), True),
    (r"тис\.", ("тисяча", "тисячі", "тисяч", "тисячі"), True),
    (r"млн\.?", ("мільйон", "мільйони", "мільйонів", "мільйона"), False),
    (r"млрд\.?", ("мільярд", "мільярди", "мільярдів", "мільярда"), False),
    (r"км/год", ("кілометр на годину", "кілометри на годину", "кілометрів на годину", "кілометра на годину"), False),
    (r"км", ("кілометр", "кілометри", "кілометрів", "кілометра"), False),
    (r"кг", ("кілограм", "кілограми", "кілограмів", "кілограма"), False),
    (r"см", ("сантиметр", "сантиметри", "сантиметрів", "сантиметра"), False),
    (r"мм", ("міліметр", "міліметри", "міліметрів", "міліметра"), False),
    (r"хв\.?", ("хвилина", "хвилини", "хвилин", "хвилини"), True),
    (r"год\.?", ("година", "години", "годин", "години"), True),
    (r"сек\.?", ("секунда", "секунди", "секунд", "секунди"), True),
    (r"дол\.", ("долар", "долари", "доларів", "долара"), False),
    (r"%", ("відсоток", "відсотки", "відсотків", "відсотка"), False),
    (r"°\s?C", ("градус", "градуси", "градусів", "градуса"), False),
]
# an abbreviation's dot, unless it also ends the sentence (then it stays in the text)
_DOT = r"(?:\.(?!\s*$|\s+[A-ZА-ЯІЇЄҐ«\"]))?"
_UK_ABBR = [  # abbreviations without numbers; unambiguous ones only
    (r"\bт\.\s?д\.(?=\s*[,;:)])", "так далі"),
    (r"\bт\.\s?д\.", "так далі."),
    (r"\bт\.\s?п\.(?=\s*[,;:)])", "тому подібне"),
    (r"\bт\.\s?п\.", "тому подібне."),
    (r"\bі\s?т\.\s?ін\.", "і таке інше."),
    (r"\bт\.\s?зв\.", "так званий"),
    (r"\bнапр\.", "наприклад"),
    (r"\bвул\.", "вулиця"),
    (r"\bпросп\.", "проспект"),
    (r"\bм\.\s?(?=[А-ЯІЇЄҐ])", "місто "),
    (r"\bст\.\s?(?=[IVXLC]+\b)", "століття "),
    (r"№\s?", "номер "),
    (r"\s&\s", " і "),
    (r"\s\+\s", " плюс "),
    (r"\bгрн\b" + _DOT, "гривень"),
    (r"\bмлн\b" + _DOT, "мільйонів"),
    (r"\bмлрд\b" + _DOT, "мільярдів"),
]


def _plural_form(n, forms):
    n = abs(n)
    if n % 10 == 1 and n % 100 != 11:
        return forms[0]
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return forms[1]
    return forms[2]


def _say_number(num, feminine=False):
    from num2words import num2words
    if "," in num or "." in num:
        return num2words(float(num.replace(",", ".")), lang="uk")
    return num2words(int(num), lang="uk", gender="feminine" if feminine else "masculine")


def _ordinal_case(n, case):
    """Ordinal adjective (masc.) in nominative / genitive / locative: only the last word inflects."""
    from num2words import num2words
    words = num2words(n, lang="uk", to="ordinal").split()
    last = words[-1]
    if case != "nom":
        if last.endswith("ій"):   # третій → третього / третьому
            last = last[:-2] + ("ього" if case == "gen" else "ьому")
        elif last.endswith("ий"):
            last = last[:-2] + ("ого" if case == "gen" else "ому")
    return " ".join(words[:-1] + [last])


def _years(text):
    # "у 2025 р." / "в 2025 році" → locative; "2025 року" / "з 2020 р." → genitive; "2025 рік" → nominative
    def repl(m):
        prep, year, word = m.group(1) or "", int(m.group(2)), m.group(3)
        if word.startswith("році") or (word == "р." and prep.strip().lower() in ("у", "в")):
            return f"{prep}{_ordinal_case(year, 'loc')} році"
        if word.startswith("рік"):
            return f"{prep}{_ordinal_case(year, 'nom')} рік"
        return f"{prep}{_ordinal_case(year, 'gen')} року"
    return re.sub(r"(\b[УуВв]\s|\b[А-ЯІЇЄҐа-яіїєґ']+\s)?(\d{3,4})\s?(р\.|року|році|рік)(?!\w)", repl, text)


# Letters Ukrainian doesn't have, typed by a Russian keyboard habit: "оксамыт" is not a word the stress dictionary
# knows, and the model reads it the Russian way. ё is left alone: it is "йо" or "ьо" depending on the neighbour.
_RU_LETTERS = str.maketrans({"ы": "и", "Ы": "И", "э": "е", "Э": "Е", "ъ": "'", "Ъ": "'"})


def fix_russian_letters(text):
    """ы → и, э → е, ъ → ' inside words that are otherwise Ukrainian-looking Cyrillic."""
    return re.sub(r"[А-Яа-яІіЇїЄєҐґЁё'\u0301]+", lambda m: m.group(0).translate(_RU_LETTERS), text)


def text_language_hint(text):
    """"uk" or "ru" when the spelling gives it away (і ї є ґ vs ы э ъ ё), None otherwise."""
    uk = len(re.findall(r"[іїєґІЇЄҐ]", text or ""))
    ru = len(re.findall(r"[ыэъёЫЭЪЁ]", text or ""))
    if uk > 2 * ru and uk >= 2:
        return "uk"
    if ru > 2 * uk and ru >= 2:
        return "ru"
    return None


def prepare_uk_text(text):
    """Make Ukrainian text easier to read aloud: apostrophes, years, numbers with units, abbreviations."""
    text = unicodedata.normalize("NFC", text)
    # stress marks (U+0301, e.g. "виши́вка") are kept: they tell the model where the stress goes
    for ch in _APOSTROPHES:
        text = re.sub(rf"(?<=\w){re.escape(ch)}(?=\w)", "'", text)
    text = fix_russian_letters(text)
    text = re.sub(r"(\d)[\s\u00a0\u202f]+(?=\d{3}\b)", r"\1", text)  # "12 500" → "12500"
    text = re.sub(r"\$\s?(\d+(?:[.,]\d+)?)", r"\1 дол.", text)
    text = re.sub(r"€\s?(\d+(?:[.,]\d+)?)", r"\1 євро", text)
    text = _years(text)
    for unit, forms, fem in _UK_UNITS:
        def repl(m, forms=forms, fem=fem):
            num = m.group(1)
            form = _plural_form(int(num), forms) if num.isdigit() else forms[3]
            # the abbreviation's dot may also end the sentence — keep it then
            ends = m.group(0).endswith(".") and re.match(r"\s*$|\s+[A-ZА-ЯІЇЄҐ«\"]", m.string[m.end():])
            return f"{_say_number(num, fem)} {form}" + ("." if ends else "")
        text = re.sub(rf"(\d+(?:[.,]\d+)?)\s?{unit}(?!\w)", repl, text)
    for pat, rep in _UK_ABBR:
        text = re.sub(pat, rep, text)
    text = re.sub(r"\.\.(?!\.)", ".", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\s*\n\s*\n\s*", "\n\n", text)
    return text.strip()


# Sounds the model can make between words: "[laughter] You really got me."
NONVERBAL_TAGS = ("laughter", "sigh", "confirmation-en", "question-en", "question-ah", "question-oh", "question-ei",
                  "question-yi", "surprise-ah", "surprise-oh", "surprise-wa", "surprise-yo", "dissatisfaction-hnn")
_TAG_RE = re.compile(r"\[(?:" + "|".join(NONVERBAL_TAGS) + r")\]")


# --------------------------------------------------------------------------
# Ukrainian word stress
# --------------------------------------------------------------------------
STRESS = "́"   # combining acute: виши́вка
# How a stress is written for the model (see tools/stress_eval.py for the measurement behind the choice).
STRESS_NOTATION = os.environ.get("OV_STRESS_NOTATION", "combining")
_stressifier = None   # (one stress per word, ambiguous words skipped), (all variants) — or False when unavailable


def _get_stressifier():
    """lang-uk's dictionary (ukrainian-word-stress, MIT) in dictionary-only mode: no Stanza, no PyTorch."""
    global _stressifier
    if _stressifier is None:
        try:
            import warnings
            from ukrainian_word_stress import OnAmbiguity, Stressifier, StressSymbol
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                _stressifier = tuple(Stressifier(stress_symbol=StressSymbol.CombiningAcuteAccent, on_ambiguity=mode,
                                                 disambiguation="dictionary")
                                     for mode in (OnAmbiguity.Skip, OnAmbiguity.All))
        except Exception:
            _stressifier = False
    return _stressifier or None


def _stress_word(token, one, every):
    """The token with its dictionary stress, or unchanged. A capitalised heteronym (За́мок at the start of a
    sentence) is as ambiguous as the lower-case word, even though the dictionary lists the proper noun once."""
    marked = one(token)
    if STRESS in marked and token[:1].isupper():
        lower = token[:1].lower() + token[1:]
        if every(lower).count(STRESS) > 1:
            return token
    return marked


def unknown_uk_words(text):
    """Words of a Ukrainian transcript the dictionary doesn't know — usually Whisper's mishearings
    ("чистише", "рифштор", "вышивкою"), which make a poor clone. None when the dictionary isn't installed."""
    s = _get_stressifier()
    if s is None:
        return None
    trie = s[0].dict
    out = []
    for w in re.findall(r"[^\W\d_]+(?:['’ʼ][^\W\d_]+)*", unicodedata.normalize("NFC", text).replace(STRESS, "")):
        n = w.replace("’", "'").replace("ʼ", "'")
        if len(n) > 2 and not any(c in trie for c in (n, n.lower(), n.capitalize(), n.title())) and w not in out:
            out.append(w)
    return out


def stress_uk_text(text):
    """Puts the dictionary stress on every Ukrainian word with a single known stress (heteronyms such as
    за́мок / замо́к and unknown words are left alone; a hand-placed mark stays). Not sent to the model — it only
    serves as the reference when takes are judged for stress."""
    s = _get_stressifier()
    if s is None:
        return text
    out = []
    for tok in re.split(r"(\s+)", unicodedata.normalize("NFC", text)):
        if not tok.strip() or STRESS in tok or _TAG_RE.fullmatch(tok):
            out.append(tok)
            continue
        try:
            out.append(_stress_word(tok, *s))
        except Exception:
            out.append(tok)
    return "".join(out)


def encode_stress(text, how=None):
    """Rewrites "ви́шивка" the way the model hears a stress best: kept as the combining mark, or as an upper-case
    vowel (вИшивка), a "+" before the vowel (в+ишивка), a spacing acute (ви´шивка) — or dropped ("none")."""
    how = how or STRESS_NOTATION
    text = unicodedata.normalize("NFC", text)
    if how == "combining":
        return text
    if how == "none":
        return text.replace(STRESS, "")
    out = []
    for i, c in enumerate(text):
        if c == STRESS:
            continue
        if i + 1 < len(text) and text[i + 1] == STRESS:
            out.append({"upper": c.upper(), "plus": "+" + c, "acute": c + "´", "apos": c + "'"}[how])
        else:
            out.append(c)
    return "".join(out)


def _wide(ch):
    """Characters that take about three times longer to say than a letter (CJK, kana, hangul)."""
    o = ord(ch)
    return 0x2E80 <= o <= 0x9FFF or 0xAC00 <= o <= 0xD7AF or 0xF900 <= o <= 0xFAFF


def _tlen(s):
    """Length of a text in "letters of speech"."""
    return sum(3 if _wide(c) else 1 for c in s)


def _sentences(para):
    """Sentence split that also works without capital letters (Arabic, Hindi, CJK …)."""
    out = []
    for piece in re.split(r"(?<=[.!?…])\s+|(?<=[。！？])\s*", para):
        if not piece:
            continue
        start = piece.lstrip("\"«„“‘'(")[:1]
        # "… т. д. і далі", "e.g. this": a lowercase letter or a dash continues the sentence
        if out and (start.islower() or start in ("—", "–", "-")):
            out[-1] = f"{out[-1]} {piece}"
        else:
            out.append(piece)
    return out


def split_segments(text, max_chars=160):
    """Sentences grouped into segments of reasonable length; paragraph breaks kept."""
    out = []
    for para in re.split(r"\n\s*\n", text):
        para = " ".join(para.split())
        if not para:
            continue
        cur = ""
        for s in _sentences(para):
            while _tlen(s) > max_chars:  # very long sentence: cut at a comma / dash / space
                limit = max(8, max_chars * len(s) // _tlen(s))  # the same budget, counted in characters
                cut = max(s.rfind(c, 0, limit) for c in (", ", " — ", "; ", "，", "、", "；"))
                if cut < limit // 3:
                    cut = s.rfind(" ", 0, limit)
                if cut <= 0:
                    cut = limit - 1  # no spaces at all (CJK, one endless token): hard cut
                piece, s = s[: cut + 1].strip(), s[cut + 1:].strip()
                if cur:
                    out.append((cur, False))
                    cur = ""
                out.append((piece, False))
            if cur and _tlen(cur) + 1 + _tlen(s) > max_chars:
                out.append((cur, False))
                cur = s
            else:
                cur = f"{cur} {s}".strip()
        if cur:
            out.append((cur, False))
        if out:
            out[-1] = (out[-1][0], True)  # paragraph end → longer pause
    return out


def _norm_for_compare(s):
    s = _TAG_RE.sub(" ", s)  # [laughter] is a sound, not a word Whisper should hear
    s = unicodedata.normalize("NFC", s.lower()).replace("\u0301", "").replace("\u00b4", "")  # Whisper never writes stress marks
    s = re.sub(r"\+(?=\w)", "", s)  # nor the "+" stress notation
    for ch in _APOSTROPHES + "'":
        s = s.replace(ch, "")
    s = s.replace("ё", "е")
    s = re.sub(r"[^\w\s]", " ", s)
    return " ".join(s.split())


def char_error_rate(ref, hyp):
    """Levenshtein distance / reference length on normalized text."""
    a, b = _norm_for_compare(ref), _norm_for_compare(hyp)
    if not a:
        return 0.0 if not b else 1.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return min(1.0, prev[-1] / len(a))


def _spoken(text, language):
    """Text as it should sound: prepared (Ukrainian) and with numbers as words."""
    if language in ("uk", "ukrainian"):
        text = prepare_uk_text(text)
    return numbers_to_words(text, language)


_NUM2WORDS_LANG = {"no": "no", "nb": "no", "pt": "pt", "zh": None}


def numbers_to_words(text, language):
    """Bare integers → words via num2words (when it knows the language)."""
    if not language or not re.search(r"\d", text):
        return text
    try:
        from num2words import num2words
    except ImportError:
        return text
    code = _NUM2WORDS_LANG.get(language, language)
    if not code:
        return text

    def repl(m):
        try:
            return num2words(int(m.group(0)), lang=code)
        except Exception:
            return m.group(0)
    return re.sub(r"(?<![\d.,])\d{1,12}(?![\d.,]\d)", repl, text)


# --------------------------------------------------------------------------
# Audio helpers
# --------------------------------------------------------------------------
def load_mono(path, sr=SR):
    import numpy as np
    from mlx_audio.audio_io import read as audio_read
    audio, file_sr = audio_read(str(path), dtype="float32", always_2d=True)
    mono = audio.mean(axis=1).astype(np.float32)
    if file_sr != sr:
        from math import gcd
        from scipy.signal import resample_poly
        g = gcd(int(file_sr), sr)
        mono = resample_poly(mono, sr // g, int(file_sr) // g).astype(np.float32)
    return mono


def write_wav(path, audio, sr=SR):
    import numpy as np
    audio = np.squeeze(np.asarray(audio, dtype=np.float32))
    if audio.ndim != 1:
        raise ValueError(T("Unexpected audio shape: {shape}", shape=audio.shape))
    pcm = (np.clip(audio, -1.0, 1.0) * 32767.0).astype(np.int16)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".part"
    with wave.open(tmp, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(pcm.tobytes())
    os.replace(tmp, path)
    return len(pcm) / sr


def frames_db(wav, sr=SR, frame=0.03):
    import numpy as np
    n = max(1, int(sr * frame))
    usable = len(wav) // n * n
    if usable == 0:
        return np.array([-120.0])
    fr = wav[:usable].reshape(-1, n)
    return 20 * np.log10(np.sqrt((fr ** 2).mean(axis=1) + 1e-12) + 1e-12)


def polish(wav, sr=SR, pad=0.1):
    """Trim silence at the edges, even out loudness, soft fades — like upstream post-processing."""
    import numpy as np
    wav = np.asarray(wav, dtype=np.float32)
    db = frames_db(wav, sr)
    n = int(sr * 0.03)
    voiced = np.where(db > max(db.max() - 45, -60))[0]
    if len(voiced):
        wav = wav[max(0, (voiced[0] - 2) * n): min(len(wav), (voiced[-1] + 3) * n)]
    rms = np.sqrt((wav ** 2).mean() + 1e-12)
    if rms > 1e-4:
        wav = wav * (0.1 / rms)
    peak = np.abs(wav).max() if len(wav) else 0
    if peak > 0.95:
        wav = wav * (0.95 / peak)
    f = min(len(wav) // 4, int(sr * 0.02))
    if f > 0:
        wav[:f] *= np.linspace(0, 1, f)
        wav[-f:] *= np.linspace(1, 0, f)
    silence = np.zeros(int(sr * pad), dtype=np.float32)
    return np.concatenate([silence, wav, silence])


# --------------------------------------------------------------------------
# Voice style: macro controls → generation parameters + light DSP
# --------------------------------------------------------------------------
# Voice design tags of OmniVoice (one per group). Anything else makes the model produce noise, so it is dropped.
INSTRUCT_GROUPS = {
    "gender": ("male", "female"),
    "age": ("child", "teenager", "young adult", "middle-aged", "elderly"),
    "pitch": ("very low pitch", "low pitch", "moderate pitch", "high pitch", "very high pitch"),
    "style": ("whisper",),
    "accent": ("american accent", "british accent", "australian accent", "canadian accent", "indian accent",
               "chinese accent", "korean accent", "japanese accent", "portuguese accent", "russian accent"),
}


def clean_instruct(instruct, language=None):
    """Keeps the known voice-design tags, one per group; accents only make sense for English."""
    wanted = [w.strip().lower() for w in re.split(r"[,;]", instruct or "")]
    out = []
    for group, values in INSTRUCT_GROUPS.items():
        if group == "accent" and language not in (None, "en"):
            continue
        hit = next((w for w in wanted if w in values), None)
        if hit:
            out.append(hit)
    if out == ["whisper"]:
        out = ["female", "whisper"]  # a bare "whisper" loses words; with a gender it is stable
    return ", ".join(out) or None


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


def resolve_style(style):
    """The Speech page's sliders → numbers the engine understands.

    intonation −1…1   flat ↔ lively: the pitch melody of the take is narrowed or widened (scale_melody);
                      guidance and temperature were measured and do not move it
    energy     −1…1   relaxed ↔ energetic: pace, pauses, melody, presence and dynamics together
    pitch      semitones; the model speaks slower/faster and the take is resampled back, so the voice
               gets deeper or lighter without vocoder artifacts
    tone       −1…1   warm ↔ bright (tilt EQ)
    pauses     multiplier for the pauses between sentences and paragraphs
    volume     dB
    """
    style = style or {}

    def val(key, lo, hi, default=0.0):
        try:
            return _clamp(float(style.get(key, default)), lo, hi)
        except (TypeError, ValueError):
            return default
    inton, energy = val("intonation", -1, 1), val("energy", -1, 1)
    return {
        "melody": _clamp((1 + (0.75 if inton > 0 else 0.6) * inton) * (1 + 0.15 * energy), 0.3, 2.0),
        "speed_mul": 1 + 0.10 * energy,
        "pitch": _clamp(val("pitch", -6, 6) + 0.4 * energy, -6, 6),
        "tone": val("tone", -1, 1),
        "presence_db": 3.0 * energy,
        "compress": 0.6 * max(0.0, energy),
        "pause_mul": _clamp(val("pauses", 0.3, 3.0, 1.0) * (1 - 0.25 * energy), 0.2, 3.5),
        "gain_db": val("volume", -12, 12),
    }


def _biquad(kind, freq, gain_db, sr=SR, q=0.707):
    """RBJ cookbook low shelf / high shelf / peak as one second-order section."""
    import numpy as np
    A = 10 ** (gain_db / 40.0)
    w = 2 * np.pi * freq / sr
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    if kind == "peak":
        b = [1 + alpha * A, -2 * cw, 1 - alpha * A]
        a = [1 + alpha / A, -2 * cw, 1 - alpha / A]
    else:
        k = 2 * np.sqrt(A) * alpha
        sign = 1 if kind == "low" else -1  # the two shelves mirror each other
        b = [A * ((A + 1) - sign * (A - 1) * cw + k), sign * 2 * A * ((A - 1) - sign * (A + 1) * cw),
             A * ((A + 1) - sign * (A - 1) * cw - k)]
        a = [(A + 1) + sign * (A - 1) * cw + k, -sign * 2 * ((A - 1) + sign * (A + 1) * cw),
             (A + 1) + sign * (A - 1) * cw - k]
    return np.array([b[0], b[1], b[2], a[0], a[1], a[2]]) / a[0]


def _compress(wav, amount, sr=SR):
    """Gentle RMS compressor (up to ~3:1 above −24 dBFS): evens out loud and quiet syllables."""
    import numpy as np
    from scipy.signal import lfilter
    k = np.exp(-1.0 / (0.02 * sr))  # 20 ms level detector
    env = np.sqrt(np.maximum(lfilter([1 - k], [1, -k], wav.astype(np.float64) ** 2), 1e-12))
    threshold, ratio = 10 ** (-24 / 20), 1 + 3.3 * amount
    gain = np.where(env > threshold, (env / threshold) ** (1 / ratio - 1), 1.0)
    return (wav * gain).astype(np.float32)


def shape_voice(wav, fx, sr=SR):
    """Tone, presence, dynamics and level of the finished take."""
    import numpy as np
    from scipy.signal import sosfilt
    wav = np.asarray(wav, dtype=np.float32)
    if not len(wav):
        return wav
    rms_in = float(np.sqrt((wav ** 2).mean() + 1e-12))
    sos = []
    if abs(fx["tone"]) > 0.02:
        sos += [_biquad("low", 220, -3.0 * fx["tone"], sr), _biquad("high", 3800, 4.0 * fx["tone"], sr)]
    if abs(fx["presence_db"]) > 0.1:
        sos.append(_biquad("peak", 3000, fx["presence_db"], sr, q=0.9))
    if sos:
        wav = sosfilt(np.array(sos), wav).astype(np.float32)
    if fx["compress"] > 0.01:
        wav = _compress(wav, fx["compress"], sr)
    rms = float(np.sqrt((wav ** 2).mean() + 1e-12))
    wav = wav * (rms_in / rms) * 10 ** (fx["gain_db"] / 20)  # EQ must not change the loudness; volume does
    knee, top = 0.8, 0.97  # soft limiter: peaks above the knee are rounded off instead of clipped
    over = np.abs(wav) > knee
    if over.any():
        wav = np.where(over, np.sign(wav) * (knee + (top - knee) * np.tanh((np.abs(wav) - knee) / (top - knee))), wav)
    return wav.astype(np.float32)


def change_pitch(wav, semitones):
    """Plays the take 2^(st/12) times faster: pitch and timbre move together (the model spoke slower to compensate)."""
    import numpy as np
    if abs(semitones) < 0.01 or not len(wav):
        return wav
    from fractions import Fraction
    from scipy.signal import resample_poly
    ratio = Fraction(2 ** (-semitones / 12.0)).limit_denominator(240)
    return resample_poly(wav, ratio.numerator, ratio.denominator).astype(np.float32)


def track_f0(wav, sr=SR, hop=0.01):
    """Rough pitch track by autocorrelation: Hz per 10 ms frame, 0 where there is no voice."""
    import numpy as np
    from scipy.signal import medfilt
    n, step = int(sr * 0.04), int(sr * hop)
    if len(wav) < n + step:
        return np.zeros(0)
    frames = np.lib.stride_tricks.sliding_window_view(np.asarray(wav, dtype=np.float64), n)[::step]
    frames = frames - frames.mean(axis=1, keepdims=True)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    ac = np.fft.irfft(np.abs(np.fft.rfft(frames, 2 * n, axis=1)) ** 2, axis=1)[:, :n]
    lo, hi = sr // 400, sr // 60
    lag = lo + np.argmax(ac[:, lo:hi], axis=1)
    strength = ac[np.arange(len(lag)), lag] / (ac[:, 0] + 1e-12)
    voiced = (strength > 0.45) & (rms > 0.15 * np.percentile(rms, 90))
    f0 = np.where(voiced, sr / lag, 0.0)
    if voiced.sum() > 5:
        smooth = medfilt(f0, 5)  # single-frame octave jumps
        f0 = np.where(voiced & (smooth > 0), smooth, 0.0)
    return f0


def scale_melody(wav, k, sr=SR, hop=0.01):
    """Widens (k > 1) or narrows (k < 1) the pitch melody around the speaker's usual pitch.

    The take is replayed at a gently varying rate — a little faster where the voice rises, a little slower
    where it falls — so there is no vocoder and nothing to phase: the waveform stays the model's own."""
    import numpy as np
    from scipy.ndimage import uniform_filter1d
    from scipy.signal import resample_poly
    if abs(k - 1.0) < 0.02:
        return wav
    f0 = track_f0(wav, sr, hop)
    voiced = f0 > 0
    if voiced.sum() < 10:
        return wav
    octaves = np.log2(f0[voiced])
    frames = np.arange(len(f0))
    dev = np.interp(frames, frames[voiced], np.clip(octaves - np.median(octaves), -0.75, 0.75))
    dev = uniform_filter1d(dev, 7)  # ~70 ms: follow the melody, not the jitter
    step = int(sr * hop)
    rate = 2 ** ((k - 1.0) * np.interp(np.arange(len(wav)), frames * step + int(sr * 0.02), dev))
    pos = np.concatenate([[0.0], np.cumsum(rate)[:-1]])
    fine = resample_poly(wav, 2, 1)  # read from a 2× oversampled copy: linear interpolation stays clean
    pos = pos[pos < len(wav) - 1] * 2
    return np.interp(pos, np.arange(len(fine)), fine).astype(np.float32)


def trim_sample(wav, sr=SR, target=10.0, limit=14.0):
    """Best stretch of a long recording: from the first word to the longest pause between 6 s and `limit`."""
    import numpy as np
    db = frames_db(wav, sr)
    hop = 0.03
    n = int(sr * hop)
    voiced = db > max(np.percentile(db, 10) + 10, -55)
    if not voiced.any():
        return wav[: int(sr * target)]
    first = int(np.argmax(voiced))
    lo, hi = first + int(6 / hop), min(len(voiced), first + int(limit / hop))
    best, run_start = None, None
    for i in range(lo, hi + 1):
        quiet = i < hi and not voiced[i]
        if quiet and run_start is None:
            run_start = i
        elif not quiet and run_start is not None:
            if best is None or i - run_start > best[1] - best[0]:
                best = (run_start, i)
            run_start = None
    if best and best[1] - best[0] >= 4:  # a pause of at least 0.12 s: cut in its middle
        cut = (best[0] + best[1]) // 2
    else:
        cut = first + int(target / hop)
    return wav[max(0, first - 3) * n: min(len(wav), cut * n)]


# --------------------------------------------------------------------------
# Engine: OmniVoice + Whisper on MLX
# --------------------------------------------------------------------------
_tts = None
_tts_dir = None
_stt = None
_stt_path = None
_prompts = {}  # prompt path -> (mtime, dict)
_steps = {"done": 0, "total": 1, "start": 0.0, "span": 1.0}


def _mx():
    import mlx.core as mx
    return mx


def _free():
    import gc
    gc.collect()
    _mx().clear_cache()


def report_memory():
    mx = _mx()
    emit("memory", active=round(mx.get_active_memory() / 1e9, 2), peak=round(mx.get_peak_memory() / 1e9, 2))


class _StepCounter:
    """Stands in for `mlx.core` inside the generation module: mx.eval runs once per decoding step."""

    def __init__(self, mx):
        self._mx = mx

    def __getattr__(self, name):
        return getattr(self._mx, name)

    def eval(self, *a, **kw):
        self._mx.eval(*a, **kw)
        _steps["done"] += 1
        frac = min(1.0, _steps["done"] / max(1, _steps["total"]))
        emit("progress", value=min(0.99, _steps["start"] + _steps["span"] * frac))


def _progress_window(start, span, total_steps):
    _steps.update(done=0, total=total_steps, start=start, span=span)


def _opt_root():
    return os.environ.get("OV_OPT_DIR") or os.path.expanduser("~/Library/Application Support/Clone'n'Speak/optimized")


def _merge_lora(base_dir, adapter_dir, out_dir):
    """PEFT LoRA → plain weights: W += (alpha/r)·B·A, `modules_to_save` replaced. Works on k2-fsa naming."""
    mx = _mx()
    cfg = json.load(open(os.path.join(adapter_dir, "adapter_config.json")))
    scale = float(cfg.get("lora_alpha", 16)) / float(cfg.get("r", 8))
    adapter = mx.load(os.path.join(adapter_dir, "adapter_model.safetensors"))
    os.makedirs(out_dir, exist_ok=True)
    for name in os.listdir(base_dir):  # configs, tokenizers, audio_tokenizer
        src = os.path.join(base_dir, name)
        if name.endswith(".safetensors") or name.endswith(".safetensors.index.json"):
            continue
        dst = os.path.join(out_dir, name)
        if not os.path.exists(dst):
            os.symlink(os.path.realpath(src), dst)
    shards = [f for f in os.listdir(base_dir) if f.endswith(".safetensors")]
    for shard in shards:
        w = mx.load(os.path.join(base_dir, shard))
        for key in list(adapter):
            k = key.replace("base_model.model.", "")
            if ".lora_A." in k:
                target = k.replace(".lora_A.weight", ".weight")
                if target in w:
                    A = adapter[key].astype(mx.float32)
                    B = adapter[key.replace("lora_A", "lora_B")].astype(mx.float32)
                    w[target] = (w[target].astype(mx.float32) + scale * (B @ A)).astype(w[target].dtype)
            elif ".lora_B." not in k and k in w:  # modules_to_save: whole tensors
                w[k] = adapter[key].astype(w[k].dtype)
        mx.save_safetensors(os.path.join(out_dir, shard), w)
        del w
        _free()
    idx = os.path.join(base_dir, "model.safetensors.index.json")
    if os.path.exists(idx):
        shutil.copy(idx, os.path.join(out_dir, "model.safetensors.index.json"))
    return out_dir


def _build_optimized(src, lora, bits, out, domain="tts"):
    """Runs in a separate process (see main): conversion memory is returned to the system afterwards."""
    merged = None
    if lora:
        merged = _merge_lora(src, lora, out + ".merge")
        src = merged
    from mlx_audio.convert import convert
    if bits >= 16:
        convert(hf_path=src, mlx_path=out, dtype="float16", model_domain=domain)
    else:
        convert(hf_path=src, mlx_path=out, quantize=True, q_bits=bits, q_group_size=64, model_domain=domain)
    if merged:
        shutil.rmtree(merged, ignore_errors=True)


def optimize(path, lora=None, bits=4, kind="tts"):
    """Converted + quantized MLX checkpoint for (model, LoRA, precision); built once, then reused."""
    import subprocess
    bits = int(bits or 16)
    if bits >= 16 and not lora and "models--mlx-community--" in path:
        return path  # already an MLX checkpoint: load the download itself, no second copy on disk
    key = hashlib.sha1(f"{os.path.realpath(path)}|{lora and os.path.realpath(lora)}|{bits}|v1".encode()).hexdigest()[:16]
    name = os.path.basename(os.path.dirname(os.path.dirname(path))).replace("models--", "") or kind
    out = os.path.join(_opt_root(), f"{name}-{bits}bit-{key}")
    if os.path.exists(os.path.join(out, ".ready")):
        return out
    status(T("Optimizing the model for this Mac ({bits})…", bits=f"{bits}-bit" if bits < 16 else "16-bit"))
    if lora:
        status(T("Merging the LoRA adapter…"))
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(_opt_root(), exist_ok=True)
    job = json.dumps({"src": path, "lora": lora, "bits": bits, "out": out, "domain": kind})
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--optimize", job],
                       stdout=sys.stderr, stderr=sys.stderr)
    if r.returncode != 0 or not os.path.exists(os.path.join(out, "config.json")):
        shutil.rmtree(out, ignore_errors=True)
        raise RuntimeError(f"Model optimization failed (exit {r.returncode})")
    open(os.path.join(out, ".ready"), "w").write(json.dumps({"src": path, "lora": lora, "bits": bits}))
    return out


def ensure_tts(spec):
    global _tts, _tts_dir
    mx = _mx()
    mx.set_cache_limit(int(spec.get("cache_mb", 128)) * 1024 * 1024)
    path = optimize(spec["path"], spec.get("lora"), spec.get("bits"), "tts")
    if _tts is not None and _tts_dir == path:
        return _tts
    unload_tts()
    if spec.get("low_memory"):
        unload_stt()
    status(T("Loading the voice model · {bits}-bit…", bits=int(spec.get("bits") or 16)))
    t0 = time.time()
    from mlx_audio.tts.utils import load_model
    from mlx_audio.tts.models.omnivoice import generation
    if not isinstance(generation.mx, _StepCounter):
        generation.mx = _StepCounter(generation.mx)
    _tts = load_model(path)
    mx.eval(_tts.parameters())
    _tts_dir = path
    status(T("Model loaded in {sec} s", sec=f"{time.time() - t0:.0f}"))
    emit("model_loaded", path=spec["path"], lora=spec.get("lora"), bits=int(spec.get("bits") or 16))
    report_memory()
    return _tts


def unload_tts():
    global _tts, _tts_dir
    if _tts is None:
        return
    _tts, _tts_dir = None, None
    _prompts.clear()
    _free()


def ensure_stt(path, low_memory=False, bits=4):
    global _stt, _stt_path
    if not path:
        raise RuntimeError(T("Speech recognition model (Whisper) is not installed. Download it on the Models page."))
    if int(bits or 16) < 16:
        path = optimize(path, None, bits, "stt")  # 8/4-bit copy when memory is tight; 16-bit uses the download as is
    if _stt is not None and _stt_path == path:
        return _stt
    unload_stt()
    if low_memory:
        unload_tts()  # never keep both models on an 8 GB Mac
    status(T("Loading Whisper · {bits}-bit…", bits=int(bits or 16)))
    from mlx_audio.stt.utils import load_model
    _stt = load_model(path)
    _stt_path = path
    return _stt


def unload_stt():
    global _stt, _stt_path
    if _stt is None:
        return
    _stt, _stt_path = None, None
    _free()


def _resample_16k(wav):
    import numpy as np
    from scipy.signal import resample_poly
    return resample_poly(np.asarray(wav, dtype=np.float32), 2, 3).astype(np.float32)  # 24 kHz → 16 kHz


def _whisper_lang(language):
    """The language as Whisper knows it, or None (it then detects the language itself)."""
    if not language or language in ("auto", "None"):
        return None
    try:
        from mlx_audio.stt.models.whisper.tokenizer import LANGUAGES
    except ImportError:
        return language
    language = {"jv": "jw", "nb": "no"}.get(language, language)
    return language if language in LANGUAGES else None


def transcribe_wave(stt, wav, language=None):
    language = _whisper_lang(language)
    kw = {"language": language} if language else {}
    text = stt.generate(_resample_16k(wav), **kw).text.strip()
    return fix_russian_letters(text) if language == "uk" else text  # "вышивкою" from accented speech


def _whisper_features(stt, wav):
    """Encoder output for the first 30 s of a 24 kHz recording."""
    from mlx_audio.stt.models.whisper.audio import N_FRAMES, log_mel_spectrogram, pad_or_trim
    mel = log_mel_spectrogram(_resample_16k(wav), n_mels=stt.dims.n_mels)
    return stt.encoder(pad_or_trim(mel, N_FRAMES, axis=-2).astype(stt.dtype)[None])


def detect_language(stt, wav):
    """Whisper's language guesses for a recording, best first: [(code, probability), …]."""
    _, probs = stt.detect_language(_whisper_features(stt, wav)[0])
    return sorted(probs.items(), key=lambda kv: -kv[1])


def fluency(stt, wav, text, language):
    """Mean log-probability Whisper gives to `text` for this audio (teacher forcing). The closer to 0, the more
    the recording sounds like clean speech in `language`; it drops for slurred words and for a foreign accent."""
    import mlx.nn as nn
    mx = _mx()
    tok = stt.get_tokenizer(language=_whisper_lang(language) or "en", task="transcribe")
    head = list(tok.sot_sequence_including_notimestamps)
    target = tok.encode(" " + text.strip())[:200]
    if not target:
        return 0.0
    logits = stt.logits(mx.array([head + target[:-1]]), _whisper_features(stt, wav))
    logp = nn.log_softmax(logits.astype(mx.float32), axis=-1)[0, len(head) - 1:]
    picked = mx.take_along_axis(logp, mx.array(target)[:, None], axis=-1)
    return float(picked.mean().item())


_EAST_SLAVIC = ("uk", "ru", "be")


def east_slavic_readings(stt, wav):
    """Ukrainian and Russian transcripts of a recording Whisper places in that group — for the user to pick."""
    ranked = detect_language(stt, wav)
    if ranked[0][0] not in _EAST_SLAVIC:
        return None
    return {"uk": transcribe_wave(stt, wav, "uk"), "ru": transcribe_wave(stt, wav, "ru")}


def transcribe_auto(stt, wav, prefer="uk"):
    """Text and language of a recording.

    Whisper's language guess is useless between Ukrainian, Russian and Belarusian: Ukrainian spoken with any
    Russian accent comes out as "ru" with probability 1.0, and the Russian transcript of it is gibberish
    ("Остальным часом мы все чистише отрымываем…"), which then ruins the clone. So within that group the
    preferred language (Ukrainian — the app's main one, or the language of the text the user typed) wins;
    the Voices page shows the choice and a wrong one is fixed with one click. Other languages: when Whisper
    is unsure, both readings are transcribed and the one it finds more convincing wins."""
    ranked = detect_language(stt, wav)
    (lang, p1), (second, p2) = ranked[0], ranked[1]
    if lang in _EAST_SLAVIC and prefer in _EAST_SLAVIC:
        return transcribe_wave(stt, wav, prefer), prefer
    text = transcribe_wave(stt, wav, lang)
    if lang in _EAST_SLAVIC:
        prefer = None
    if p1 < 0.8 and p2 > 0.05:
        other = transcribe_wave(stt, wav, second)
        if other and fluency(stt, wav, other, second) > fluency(stt, wav, text, lang):
            text, lang = other, second
    return text, {"jw": "jv"}.get(lang, lang)


# --------------------------------------------------------------------------
# Voice likeness: ECAPA-TDNN speaker embeddings (speechbrain/spkrec-ecapa-voxceleb, Apache-2.0) on MLX
# --------------------------------------------------------------------------
# The weights are a PyTorch checkpoint; they are read straight from its zip (no PyTorch needed).
SPEAKER_REPO = "speechbrain/spkrec-ecapa-voxceleb"
_speaker = None


def _torch_zip_load(path):
    """state_dict of a PyTorch zip checkpoint as numpy arrays (float32 tensors only, which is all ECAPA has)."""
    import pickle
    import zipfile
    from collections import OrderedDict

    import numpy as np
    zf = zipfile.ZipFile(path)
    names = zf.namelist()
    root = names[0].split("/")[0]
    dtypes = {"FloatStorage": np.float32, "DoubleStorage": np.float64, "HalfStorage": np.float16,
              "LongStorage": np.int64, "IntStorage": np.int32, "BFloat16Storage": None}
    storages = {}

    def storage(dtype, key):
        if key not in storages:
            raw = zf.read(f"{root}/data/{key}")
            storages[key] = np.frombuffer(raw, dtype=dtype) if dtype is not None else None
        return storages[key]

    def rebuild(st, offset, size, stride, *rest):
        if st is None:
            return None
        size, stride = tuple(size), tuple(stride)
        if not size:
            return st[offset:offset + 1].reshape(())
        item = st.itemsize
        return np.lib.stride_tricks.as_strided(st[offset:], shape=size, strides=[s * item for s in stride]).copy()

    class _Storage:
        def __init__(self, name):
            self.dtype = dtypes.get(name, np.float32)

    class Unpickler(pickle.Unpickler):
        def find_class(self, module, name):
            if module == "torch._utils" and name.startswith("_rebuild_tensor"):
                return rebuild
            if module == "torch._utils" and name == "_rebuild_parameter":
                return lambda data, *a: data
            if module == "torch" and name.endswith("Storage"):
                return _Storage(name)
            if module == "collections" and name == "OrderedDict":
                return OrderedDict
            if module == "torch" and name in ("device", "Size"):
                return lambda *a: a
            return super().find_class(module, name)

        def persistent_load(self, pid):
            _, kind, key, _location, _n = pid
            return storage(kind.dtype if isinstance(kind, _Storage) else np.float32, key)

    data = Unpickler(zf.open(f"{root}/data.pkl")).load()
    return {k: v for k, v in data.items() if v is not None}


def _fbank(wav16, n_mels=80):
    """speechbrain's Fbank: 25 ms Hamming window, 10 ms hop, power spectrum, triangular mel filters, 10·log10 with an
    80 dB floor, then the per-utterance mean removed (InputNormalization, norm_type="sentence")."""
    import numpy as np
    n_fft, hop, sr = 400, 160, 16000
    x = np.pad(np.asarray(wav16, dtype=np.float32), (n_fft // 2, n_fft // 2))
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop]
    spec = np.abs(np.fft.rfft(frames * np.hamming(n_fft + 1)[:-1].astype(np.float32), n_fft)) ** 2
    mel = lambda f: 2595 * np.log10(1 + f / 700.0)  # noqa: E731
    hz = 700 * (10 ** (np.linspace(mel(0), mel(sr / 2), n_mels + 2) / 2595) - 1)
    band, central = (hz[1:] - hz[:-1])[:-1], hz[1:-1]
    freqs = np.linspace(0, sr / 2, n_fft // 2 + 1)
    slope = (freqs[None, :] - central[:, None]) / band[:, None]
    fb = np.maximum(0, np.minimum(slope + 1, -slope + 1))
    feats = 10 * np.log10(np.maximum(spec @ fb.T, 1e-10))
    feats = np.maximum(feats, feats.max() - 80)
    return (feats - feats.mean(axis=0, keepdims=True)).astype(np.float32)


class _Ecapa:
    """speechbrain ECAPA_TDNN (channels 1024×4 + 3072, attention 128, global context, 192-dim output), inference only."""

    def __init__(self, w):
        import mlx.core as mx
        self.mx = mx
        self.w = {k: mx.array(v) for k, v in w.items()}

    def conv(self, x, name, dilation=1):
        """Conv1d with reflect "same" padding. x: [T, C_in] → [T, C_out]."""
        mx = self.mx
        weight = self.w[name + ".weight"]  # [out, in, k]
        k = weight.shape[-1]
        pad = dilation * (k - 1) // 2
        if pad:
            left = x[1:pad + 1][::-1]
            right = x[-pad - 1:-1][::-1]
            x = mx.concatenate([left, x, right], axis=0)
        y = mx.conv1d(x[None], weight.transpose(0, 2, 1), dilation=dilation)[0]
        b = self.w.get(name + ".bias")
        return y + b if b is not None else y

    def bn(self, x, name):
        mx = self.mx
        w = self.w
        return (x - w[name + ".running_mean"]) / mx.sqrt(w[name + ".running_var"] + 1e-5) * w[name + ".weight"] + w[name + ".bias"]

    def tdnn(self, x, name, dilation=1):
        return self.bn(self.mx.maximum(self.conv(x, name + ".conv.conv", dilation), 0), name + ".norm.norm")

    def se_res2net(self, x, i, dilation):
        mx = self.mx
        p = f"blocks.{i}"
        out = self.tdnn(x, p + ".tdnn1")
        parts = mx.split(out, 8, axis=1)
        ys = [parts[0]]
        for s in range(1, 8):
            inp = parts[s] if s == 1 else parts[s] + ys[-1]
            ys.append(self.tdnn(inp, f"{p}.res2net_block.blocks.{s - 1}", dilation))
        out = self.tdnn(mx.concatenate(ys, axis=1), p + ".tdnn2")
        s = out.mean(axis=0, keepdims=True)
        s = mx.maximum(self.conv(s, p + ".se_block.conv1.conv"), 0)
        s = mx.sigmoid(self.conv(s, p + ".se_block.conv2.conv"))
        return out * s + x

    def __call__(self, feats):
        mx = self.mx
        x = mx.array(feats)
        x = self.tdnn(x, "blocks.0")
        xl = []
        for i, d in ((1, 2), (2, 3), (3, 4)):
            x = self.se_res2net(x, i, d)
            xl.append(x)
        x = self.tdnn(mx.concatenate(xl, axis=1), "mfa")
        T = x.shape[0]
        mean = x.mean(axis=0, keepdims=True)
        std = mx.sqrt(mx.maximum(((x - mean) ** 2).mean(axis=0, keepdims=True), 1e-12))
        attn = mx.concatenate([x, mx.broadcast_to(mean, x.shape), mx.broadcast_to(std, x.shape)], axis=1)
        attn = self.conv(mx.tanh(self.tdnn(attn, "asp.tdnn")), "asp.conv.conv")
        attn = mx.softmax(attn, axis=0)
        m = (attn * x).sum(axis=0, keepdims=True)
        s = mx.sqrt(mx.maximum((attn * (x - m) ** 2).sum(axis=0, keepdims=True), 1e-12))
        pooled = self.bn(mx.concatenate([m, s], axis=1), "asp_bn.norm")
        emb = self.conv(pooled, "fc.conv")[0]
        return emb / mx.sqrt((emb ** 2).sum())


def speaker_model():
    """Loaded on first use; the checkpoint (83 MB) comes into the Hugging Face cache like every other model."""
    global _speaker
    if _speaker is None:
        from huggingface_hub import hf_hub_download
        _speaker = _Ecapa(_torch_zip_load(hf_hub_download(SPEAKER_REPO, "embedding_model.ckpt")))
    return _speaker


def voice_print(wav, sr=SR):
    """192-dim unit vector of who is speaking (24 kHz mono in)."""
    import numpy as np
    from scipy.signal import resample_poly
    wav16 = resample_poly(np.asarray(wav, dtype=np.float32), 2, 3) if sr == 24000 else np.asarray(wav, dtype=np.float32)
    emb = speaker_model()(_fbank(wav16))
    _mx().eval(emb)
    return np.array(emb)


def likeness(a, b):
    """Cosine similarity of two voice prints: ~0.9+ the same voice, below ~0.5 different people."""
    import numpy as np
    return float(np.dot(a, b))


# --------------------------------------------------------------------------
# Voice prompts (.npz: audio tokens + transcript)
# --------------------------------------------------------------------------
def build_prompt(tts, audio, ref_text):
    mx = _mx()
    from mlx_audio.tts.models.omnivoice.utils import create_voice_clone_prompt
    tokens = create_voice_clone_prompt(audio, tokenizer=tts.audio_tokenizer, ref_text=ref_text)
    mx.eval(tokens)
    return tokens


def save_prompt(path, tokens, ref_text, version=1):
    import numpy as np
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.npz"
    np.savez(tmp, tokens=np.array(tokens), ref_text=np.array(ref_text), version=np.array(version))
    os.replace(tmp, path)
    _prompts.pop(path, None)


def load_prompt(voice, tts):
    """voice = {"prompt": .npz, "audio": reference.wav, "ref_text": …}; rebuilt from the sample if missing."""
    import numpy as np
    mx = _mx()
    path = voice.get("prompt")
    if path and os.path.exists(path):
        mtime = os.path.getmtime(path)
        cached = _prompts.get(path)
        if cached and cached[0] == mtime:
            return cached[1]
        data = np.load(path)
        prompt = {"tokens": mx.array(data["tokens"]), "ref_text": str(data["ref_text"])}
        _prompts[path] = (mtime, prompt)
        return prompt
    audio, ref_text = voice.get("audio"), (voice.get("ref_text") or "").strip()
    if not audio or not os.path.exists(audio) or not ref_text:
        raise RuntimeError(T("This voice needs to be re-created: its sample or text is missing."))
    tokens = build_prompt(tts, audio, ref_text)  # voices made by the PyTorch version: re-encode once
    if path:
        save_prompt(path, tokens, ref_text)
    return {"tokens": tokens, "ref_text": ref_text}


# A phrase per language for ensure_adapted(): everyday words, about eight seconds of speech.
_BRIDGE = {
    "uk": "Привіт! Сьогодні чудовий день, щоб розповісти цікаву історію. Гарні гілки ялини хитаються від вітру, а їжачок біжить до річки.",
    "ru": "Привет! Сегодня отличный день, чтобы рассказать интересную историю. Широкие ветви ели качаются от ветра, а ёжик бежит к реке.",
    "en": "Hello! Today is a wonderful day to tell an interesting story. The branches of the fir tree sway in the wind, and a little hedgehog runs to the river.",
    "de": "Hallo! Heute ist ein schöner Tag, um eine spannende Geschichte zu erzählen. Die Zweige der Fichte wiegen sich im Wind, und ein kleiner Igel läuft zum Fluss.",
    "pl": "Cześć! Dzisiaj jest piękny dzień, żeby opowiedzieć ciekawą historię. Gałęzie świerku kołyszą się na wietrze, a mały jeż biegnie do rzeki.",
    "fr": "Bonjour ! C'est une belle journée pour raconter une histoire intéressante. Les branches du sapin se balancent au vent, et un petit hérisson court vers la rivière.",
    "es": "¡Hola! Hoy es un día estupendo para contar una historia interesante. Las ramas del abeto se mueven con el viento y un pequeño erizo corre hacia el río.",
    "it": "Ciao! Oggi è una giornata splendida per raccontare una storia interessante. I rami dell'abete ondeggiano al vento e un piccolo riccio corre verso il fiume.",
    "pt": "Olá! Hoje é um dia maravilhoso para contar uma história interessante. Os ramos do abeto balançam ao vento e um pequeno ouriço corre para o rio.",
    "cs": "Ahoj! Dnes je krásný den na vyprávění zajímavého příběhu. Větve smrku se houpou ve větru a malý ježek běží k řece.",
    "nl": "Hallo! Vandaag is een prachtige dag om een interessant verhaal te vertellen. De takken van de spar wiegen in de wind en een kleine egel rent naar de rivier.",
    "tr": "Merhaba! Bugün ilginç bir hikâye anlatmak için harika bir gün. Ladin dalları rüzgârda sallanıyor ve küçük bir kirpi nehre doğru koşuyor.",
}


def bridge_text(language, text):
    """The phrase the voice learns a language on: a built-in one, else the beginning of the text itself."""
    if language in _BRIDGE:
        return _BRIDGE[language]
    out = ""
    for seg, _ in split_segments(_TAG_RE.sub(" ", text)):
        out = f"{out} {seg}".strip()
        if _tlen(out) >= 90:
            break
    return out if _tlen(out) >= 30 else None


# Second phrase per language for ensure_adapted(): more takes to choose from, different sounds
_BRIDGE_MORE = {
    "uk": "Добрий день! Я розповім вам про нашу нову колекцію тканин і про те, як їх обрати для вашого дому.",
    "ru": "Добрый день! Я расскажу вам о нашей новой коллекции тканей и о том, как выбрать их для вашего дома.",
    "en": "Good afternoon! Let me tell you about our new collection of fabrics and how to choose them for your home.",
}


def sample_print(voice):
    """Voice print of the person behind a cloned voice (from the real sample), cached next to it."""
    import numpy as np
    audio = voice.get("audio")
    if not audio or not os.path.exists(audio):
        return None
    cache = os.path.splitext(audio)[0] + ".print.npy"
    try:
        if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(audio):
            return np.load(cache)
        vp = voice_print(load_mono(audio))
        np.save(cache, vp)
        return vp
    except Exception:  # no network for the first download, …: likeness is a bonus
        traceback.print_exc(file=sys.stderr)
        return None


ADAPT_VERSION = 2  # adapted prompts older than this are learned again


def ensure_adapted(req, language, text):
    """Speech in a language other than the sample's keeps the sample's accent: the model continues the way
    its prompt sounds. So the cloned voice first says short phrases in the target language and the best take
    becomes the prompt for that language from then on — prompt and text now match, the accent is gone.

    "Best" is first of all *the most like the person*: each generated take drifts a little from the real voice
    (ECAPA likeness 0.78…0.87 for one Russian sample), and picking only by pronunciation used to pick a take
    that no longer sounded like them. So six takes are scored by likeness to the real sample, with Whisper's
    pronunciation score as the tie-breaker. One round only: each further round drifts further.

    Returns the path of the adapted prompt (cached in the voice's folder), or None when there is nothing to do."""
    voice = req["voice"]
    path = voice.get("adapt_prompt")
    if not path or not language:
        return None
    if os.path.exists(path):
        import numpy as np
        try:
            with np.load(path) as data:
                if int(data["version"]) >= ADAPT_VERSION:
                    return path
        except Exception:
            pass
        # learned by 1.0.0's method (one take, picked by pronunciation only): sounded less like the person
    phrases = [b for b in (bridge_text(language, text), _BRIDGE_MORE.get(language)) if b]
    if not phrases:
        return None
    low_memory = bool(req.get("low_memory"))
    spec = dict(req["model"], low_memory=low_memory)
    name = voice.get("adapt_name") or language
    asr = req.get("asr_path") or (req.get("improve") or {}).get("asr_path")
    status(T("Teaching the voice {lang} pronunciation (once per voice)…", lang=name))
    tts = ensure_tts(spec)
    base = load_prompt(voice, tts)
    plan = [(phrase, k) for phrase in phrases for k in range(3)]
    takes = []
    for i, (phrase, k) in enumerate(plan):
        status(T("Teaching the voice {lang} pronunciation: take {i} of {n}…", lang=name, i=i + 1, n=len(plan)))
        _progress_window(i / len(plan) * 0.5, 0.5 / len(plan), 32)
        takes.append({"text": phrase, "wav": _speak(tts, phrase, language, base, {}, seed=4242 + 97 * k)})
    status(T("Choosing the take that sounds most like you…"))
    me = sample_print(voice)
    for t in takes:
        t["like"] = likeness(voice_print(t["wav"]), me) if me is not None else 0.0
        t["say"] = 0.0
    if asr:
        try:
            stt = ensure_stt(asr, low_memory, req.get("asr_bits") or 8)
            for t in takes:
                heard = transcribe_wave(stt, t["wav"], language)
                cer = char_error_rate(_spoken(t["text"], language), _spoken(heard, language))
                t["say"] = 0.3 * (fluency(stt, t["wav"], t["text"], language) if _whisper_lang(language) else 0.0) - cer
        except Exception:  # Whisper is a bonus here
            traceback.print_exc(file=sys.stderr)
        if low_memory:
            unload_stt()
        tts = ensure_tts(spec)
    import numpy as np
    # the two best takes together: measured on a Russian sample speaking Ukrainian, two takes cut Whisper's
    # error rate from 5.7 % (original sample) to 2.6 % at about the same likeness (0.78 vs 0.81);
    # a single take only got to 4.1 %
    best = sorted(takes, key=lambda t: t["like"] + t["say"], reverse=True)[:2]
    gap = np.zeros(int(SR * 0.25), dtype=np.float32)
    sample = os.path.splitext(path)[0] + ".wav"
    write_wav(sample, np.concatenate([best[0]["wav"], gap, best[1]["wav"]]) if len(best) > 1 else best[0]["wav"])
    words = " ".join(t["text"] for t in best)
    save_prompt(path, build_prompt(tts, sample, words), words, version=ADAPT_VERSION)
    if me is not None:
        likes = ", ".join(f"{t['like']:.2f}" for t in takes)
        print(f"adapted prompt: takes' likeness {likes}", file=sys.stderr, flush=True)
    return path


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
def cmd_hello(req):
    import mlx.core as mx
    import importlib.metadata as m
    return {"python": sys.version.split()[0], "mlx": m.version("mlx"), "mlx_audio": m.version("mlx-audio"),
            "metal": bool(mx.metal.is_available())}


def _listen(req, wav, language):
    """(text, language) of a sample; language None/"auto" = detect it (a typed transcript's spelling decides
    between Ukrainian and Russian, else Ukrainian)."""
    stt = ensure_stt(req.get("asr_path"), req.get("low_memory"), req.get("asr_bits") or 8)
    if language in (None, "", "auto"):
        status(T("Detecting the language of the sample…"))
        return transcribe_auto(stt, wav, text_language_hint(req.get("ref_text")) or "uk")
    status(T("Transcribing the voice sample…"))
    return transcribe_wave(stt, wav, language), language


def _readings(req, wav):
    """Both readings when the language was left to auto-detection and nothing tells Ukrainian from Russian."""
    if req.get("language") not in (None, "", "auto") or text_language_hint(req.get("ref_text")):
        return None
    stt = ensure_stt(req.get("asr_path"), req.get("low_memory"), req.get("asr_bits") or 8)
    status(T("Ukrainian or Russian? Transcribing both…"))
    return east_slavic_readings(stt, wav)


def cmd_transcribe(req):
    wav = load_mono(req["audio"])
    readings = _readings(req, wav)
    if readings:
        return _check_words({"text": readings["uk"], "language": "uk", "readings": readings}, readings["uk"], "uk")
    text, language = _listen(req, wav, req.get("language"))
    return _check_words({"text": text, "language": language}, text, language)


def _check_words(result, text, language):
    """Adds the words to double-check in a Ukrainian sample transcript."""
    if language in ("uk", "ukrainian"):
        odd = unknown_uk_words(text)
        if odd:
            result["unknown_words"] = odd
    return result


def cmd_clone(req):
    import glob
    audio = req["audio"]
    if not os.path.isfile(audio):
        raise FileNotFoundError(T("Voice sample not found: {path}", path=audio))
    ref_text = (req.get("ref_text") or "").strip()
    language = req.get("language")
    auto = language in (None, "", "auto")
    language = None if auto else language
    wav = load_mono(audio)
    result = {}
    if len(wav) / SR > 20 and (req.get("asr_path") or not ref_text):
        # minutes of audio as a prompt would make every phrase slow and memory-hungry
        wav = trim_sample(wav)
        status(T("The sample is long — keeping its best {sec} seconds…", sec=round(len(wav) / SR)))
        audio = os.path.splitext(req["out"])[0] + ".trimmed.wav"
        write_wav(audio, wav)
        result["trimmed"] = audio
        ref_text = ""  # the old transcript no longer matches the shorter recording
    heard = None
    readings = _readings(req, wav) if auto and not ref_text and req.get("asr_path") else None
    if readings:
        # Whisper can't tell accented Ukrainian from Russian: clone as Ukrainian, the app asks which it was
        heard = ref_text = readings["uk"]
        language = "uk"
        result["readings"] = readings
        emit("transcript", text=ref_text)
    elif not ref_text or (req.get("asr_path") and req.get("check_text", True)):
        # a transcript that doesn't match the recording is the #1 cause of bad clones — check it
        heard, language = _listen(req, wav, language)
        if not ref_text:
            ref_text = heard
            emit("transcript", text=ref_text)
    tts = ensure_tts(dict(req["model"], low_memory=bool(req.get("low_memory"))))
    status(T("Creating the voice profile…"))
    tokens = build_prompt(tts, audio, ref_text)
    save_prompt(req["out"], tokens, ref_text)
    for stale in glob.glob(os.path.join(glob.escape(os.path.dirname(req["out"])), "adapted-*")):
        os.remove(stale)  # pronunciation learned from the previous sample
    result.update(path=req["out"], ref_text=ref_text, seconds=round(int(tokens.shape[0]) / 25.0, 2))
    _check_words(result, ref_text, language)
    if auto and language:
        result["language"] = language
    if heard is not None and heard != ref_text:
        cer = char_error_rate(_spoken(ref_text, language), _spoken(heard, language))
        odd_heard = unknown_uk_words(heard) if language in ("uk", "ukrainian") else None
        odd_typed = unknown_uk_words(ref_text) if odd_heard is not None else None
        # Whisper mishears accented Ukrainian ("рифштор"): its text is no better when it has more non-words
        if cer > 0.12 and not (odd_heard is not None and len(odd_heard) > len(odd_typed)):
            result["mismatch"] = {"heard": heard, "cer": round(cer, 3)}
    report_memory()
    return result


# --------------------------------------------------------------------------
# Take scoring: clarity, Ukrainian-ness, likeness and stress
# --------------------------------------------------------------------------
_VOWELS = "аеєиіїоуюяыэё"


def _band_env(wav, sr=SR, hop=0.005):
    """Loudness of the vowel band (250–2500 Hz) per 5 ms."""
    import numpy as np
    from scipy.ndimage import uniform_filter1d
    from scipy.signal import butter, sosfiltfilt
    x = sosfiltfilt(butter(4, [250, 2500], btype="band", fs=sr, output="sos"), np.asarray(wav, dtype=np.float64))
    h = int(sr * hop)
    n = len(x) // h
    if n < 4:
        return np.zeros(0)
    return uniform_filter1d(np.sqrt((x[: n * h].reshape(n, h) ** 2).mean(axis=1) + 1e-12), 5)


def stressed_syllable(wav, n, sr=SR):
    """Which of a word's n syllables sounds stressed (1-based), from the vowel nuclei: the stressed Ukrainian vowel is
    longer, louder and higher. 0 when the nuclei can't be told apart. 64 % right on real Ukrainian speech
    (speech-uk/opentts, 445 words), against 33–50 % by chance."""
    import numpy as np
    from scipy.signal import find_peaks
    env = _band_env(wav, sr)
    if len(env) < 8 or n < 2:
        return 0
    hop = 0.005
    f0 = track_f0(wav, sr, 0.01)
    f0i = np.repeat(f0, 2)[: len(env)] if len(f0) else np.zeros(len(env))
    f0i = np.pad(f0i, (0, max(0, len(env) - len(f0i))))
    peaks, props = np.zeros(0, dtype=int), {}
    for prom in (0.25, 0.15, 0.08, 0.04, 0.02):
        peaks, props = find_peaks(env, distance=int(0.055 / hop), prominence=env.max() * prom)
        if len(peaks) >= n:
            break
    if len(peaks) < n:
        return 0
    if len(peaks) > n:
        peaks = np.sort(peaks[np.argsort(props["prominences"])[::-1][:n]])
    bounds = [0] + [int(np.argmin(env[a:b]) + a) for a, b in zip(peaks[:-1], peaks[1:])] + [len(env)]
    voiced = f0i[f0i > 0]
    med = float(np.median(voiced)) if len(voiced) else 0.0
    scores = []
    for k, pk in enumerate(peaks):
        a, b = bounds[k], bounds[k + 1]
        half = env[pk] * 0.5
        lo = hi = pk
        while lo > a and env[lo] > half:
            lo -= 1
        while hi < b - 1 and env[hi] > half:
            hi += 1
        seg = f0i[lo:hi + 1]
        fmax = float(seg[seg > 0].max()) if (seg > 0).any() and med else med
        scores.append(2 * np.log((hi - lo + 1) * hop) + 0.5 * np.log(float((env[lo:hi + 1] ** 2).sum()) * hop)
                      + 0.5 * (np.log(fmax / med) if med else 0.0))
    return int(np.argmax(scores)) + 1


def _plain_word(w):
    w = unicodedata.normalize("NFC", w.lower()).replace(STRESS, "")
    return re.sub(r"[^а-яіїєґ']", "", w.replace("’", "'").replace("ʼ", "'"))


def stress_agreement(stt, wav, text):
    """Share of dictionary-stressed words (2+ syllables) spoken with that stress, or None when there are none."""
    marked = []
    for tok in stress_uk_text(text).split():
        tok = unicodedata.normalize("NFC", tok)
        plain = _plain_word(tok)
        if sum(c in _VOWELS for c in plain) < 2 or tok.count(STRESS) != 1:
            continue
        before = _plain_word(tok[: tok.index(STRESS)])
        marked.append((plain, sum(c in _VOWELS for c in before)))
    if not marked:
        return None
    res = stt.generate(_resample_16k(wav), language="uk", word_timestamps=True, temperature=0.0)
    heard = [(_plain_word(w["word"]), float(w["start"]), float(w["end"])) for sg in (res.segments or []) for w in sg.get("words", [])]
    hits = total = j = 0
    for word, truth in marked:
        for k in range(j, len(heard)):
            if heard[k][0] == word:
                j = k + 1
                a, b = max(0, int((heard[k][1] - 0.02) * SR)), min(len(wav), int((heard[k][2] + 0.02) * SR))
                got = stressed_syllable(wav[a:b], sum(c in _VOWELS for c in word)) if b - a > SR * 0.08 else 0
                if got:
                    total += 1
                    hits += got == truth
                break
    return hits / total if total else None


def score_take(stt, take, text, language, me=None):
    """One number per take, higher is better: what Whisper hears (errors), how native it sounds in the language
    (Whisper's likelihood of the text — catches a Russian "и" in Ukrainian), how much it sounds like the person,
    and for Ukrainian how many words carry the dictionary stress."""
    wav = take["audio"]
    heard = transcribe_wave(stt, wav, language)
    take["heard"] = heard
    take["cer"] = char_error_rate(_spoken(text, language), _spoken(heard, language))
    score = -2.0 * take["cer"]
    if _whisper_lang(language):
        try:
            score += 0.5 * fluency(stt, wav, _spoken(text, language).replace(STRESS, ""), language)
        except Exception:
            traceback.print_exc(file=sys.stderr)
    if me is not None:
        try:
            take["likeness"] = likeness(voice_print(wav), me)
            score += 1.0 * take["likeness"]
        except Exception:
            traceback.print_exc(file=sys.stderr)
    if language in ("uk", "ukrainian") and _get_stressifier() is not None:
        try:
            take["stress"] = stress_agreement(stt, wav, text)
            if take["stress"] is not None:
                score += 0.3 * take["stress"]
        except Exception:
            traceback.print_exc(file=sys.stderr)
    take["score"] = score
    return score


_GEN_KEYS = {"num_step": "num_steps", "guidance_scale": "guidance_scale", "t_shift": "t_shift",
             "layer_penalty_factor": "layer_penalty_factor", "position_temperature": "position_temperature",
             "class_temperature": "class_temperature"}


def _speak(tts, text, language, prompt, gen, speed=1.0, seed=None, pitch=0.0, melody=1.0):
    import numpy as np
    from mlx_audio.tts.models.omnivoice.duration import RuleDurationEstimator
    mx = _mx()
    if seed is not None:
        mx.random.seed(seed)
    plain = text.replace(STRESS, "")  # the pace is estimated from the letters, not the marks
    # Only marks placed by hand reach the model. Dictionary marks on every word were tried and hurt:
    # on two Ukrainian clones Whisper's error rate went 4.3 % → 5.9 % (text) → 7.9 % (text + sample transcript),
    # 1.0 % → 4.3 % → 8.3 % on the other, with no gain in stress placement. See README → Stress.
    text = encode_stress(text)
    kw = dict(gen)
    # a pitch change is "speak slower, play faster" (see change_pitch): the model's own pace absorbs it
    pace = _clamp((speed or 1.0) / 2 ** (pitch / 12.0), 0.55, 1.8)
    if prompt:
        kw.update(ref_tokens=prompt["tokens"], ref_text=prompt["ref_text"].replace(STRESS, ""))
        # speaking rate of this voice: estimate from the sample (upstream does the same)
        tokens = RuleDurationEstimator().estimate_duration(plain, prompt["ref_text"].replace(STRESS, ""),
                                                           int(prompt["tokens"].shape[0]))
        kw["duration_s"] = max(0.6, tokens / 25.0) / pace
    elif abs(pace - 1.0) > 1e-3:
        kw["duration_s"] = max(0.6, RuleDurationEstimator().estimate_duration(plain, "Nice to meet you.", 25) * 1.15 / 25.0) / pace
    res = list(tts.generate(text=text, language=language or "None", **kw))
    audio = np.array(res[0].audio, dtype=np.float32)
    return polish(scale_melody(change_pitch(audio, pitch), melody), pad=0.0)


def cmd_synth(req):
    import numpy as np
    text = (req.get("text") or "").strip()
    if not text:
        raise ValueError(T("The text is empty"))
    p = dict(req.get("params") or {})
    language = req.get("language") or None
    if language in ("auto", "None"):
        language = None
    if language in ("uk", "ukrainian"):
        text = prepare_uk_text(text) if p.get("prepare_text", True) else fix_russian_letters(text)
    if p.get("normalize_text", True):
        text = numbers_to_words(text, language)
    voice = req.get("voice") or None
    fx = resolve_style(p.get("style"))
    gen = {v: p[k] for k, v in _GEN_KEYS.items() if p.get(k) is not None}
    instruct = None if voice else clean_instruct(p.get("instruct"), language)  # with a clone the sample decides
    if instruct:
        gen["instruct"] = instruct
    speed = float(p.get("speed") or 1.0) * fx["speed_mul"]
    seed = p.get("seed")
    seed = int(seed) if seed is not None and int(seed) >= 0 else None
    low_memory = bool(req.get("low_memory"))
    t0 = time.time()

    steps = int(gen.get("num_steps", 32))
    segments = split_segments(text)
    improve = req.get("improve") or None
    rounds = max(1, int(improve.get("attempts", 3))) if improve else 1
    good = float(improve.get("threshold", 0.08)) if improve else 1.0
    adapted = ensure_adapted(req, language, text) if voice else None

    base_seed = seed if seed is not None else int(time.time()) % 100000
    report = None
    n_takes = rounds  # with auto-improve every phrase is spoken this many times and the best take is kept
    speak_share = 0.75 if improve else 1.0
    candidates = [[] for _ in segments]
    tts = ensure_tts(dict(req["model"], low_memory=low_memory))
    prompt = load_prompt({"prompt": adapted} if adapted else voice, tts) if voice else None
    total = len(segments) * n_takes
    for k in range(n_takes):
        for i, (seg, _) in enumerate(segments):
            done = k * len(segments) + i
            _progress_window(speak_share * done / total, speak_share / total, steps)
            label = T("Phrase {i} of {n}", i=i + 1, n=len(segments)) + (T(" · take {a} of {b}", a=k + 1, b=n_takes) if n_takes > 1 else "")
            status(label + T(": speaking…"))
            s = base_seed + i * 101 + k * 7919 if (improve or seed is not None) else None
            wav = _speak(tts, seg, language, prompt, gen, speed, s, fx["pitch"], fx["melody"])
            candidates[i].append({"audio": wav, "cer": 0.0, "heard": None})
    if improve:
        # 2) judge every take at once (on 8 GB Macs the synthesizer is unloaded while Whisper runs)
        status(T("Choosing the best take of each phrase…"))
        stt = ensure_stt(improve.get("asr_path"), low_memory, req.get("asr_bits") or 8)
        me = sample_print(voice) if voice else None
        for i, (seg, _) in enumerate(segments):
            emit("progress", value=min(0.99, speak_share + (1 - speak_share) * i / len(segments)))
            for c in candidates[i]:
                score_take(stt, c, seg, language, me)
        if low_memory:
            unload_stt()
    takes = [max(c, key=lambda t: t.get("score", 0.0)) for c in candidates]
    pieces = []
    for i, (seg, para_end) in enumerate(segments):
        pieces.append(takes[i]["audio"])
        if i < len(segments) - 1:
            pieces.append(np.zeros(int(SR * (0.45 if para_end else 0.18) * fx["pause_mul"]), dtype=np.float32))
    silence = np.zeros(int(SR * 0.1), dtype=np.float32)
    audio = np.concatenate([silence, shape_voice(np.concatenate(pieces), fx), silence])
    if improve:
        weight = sum(len(s) for s, _ in segments) or 1
        clarity = 1.0 - sum(takes[i]["cer"] * len(segments[i][0]) for i in range(len(segments))) / weight
        problems = [{"text": segments[i][0], "heard": takes[i]["heard"], "cer": round(takes[i]["cer"], 3)}
                    for i in range(len(segments)) if takes[i]["cer"] > good]
        report = {"clarity": round(max(0.0, clarity), 3), "segments": len(segments), "problems": problems}
        judged = [t["stress"] for t in takes if t.get("stress") is not None]
        if judged:
            report["stress"] = round(sum(judged) / len(judged), 3)
    duration = write_wav(req["out"], audio)
    emit("progress", value=1.0)
    report_memory()
    result = {"path": req["out"], "seconds": round(duration, 2), "elapsed": round(time.time() - t0, 1),
              "sample_rate": SR, "text": text, "adapted": bool(adapted)}
    if report:
        result.update(report)
    if voice and p.get("likeness", True):
        me = sample_print(voice)
        if me is not None:
            try:
                result["likeness"] = round(likeness(voice_print(audio), me), 3)
            except Exception:
                traceback.print_exc(file=sys.stderr)
    return result
def cmd_prepare(req):
    """Preview what the text will sound like after preparation."""
    lang = req.get("language") or "uk"
    return {"text": _spoken(req.get("text") or "", lang)}


# --------------------------------------------------------------------------
# Voice sample quality
# --------------------------------------------------------------------------
def cmd_analyze(req):
    """Quick quality report of a voice sample: length, loudness, clipping, noise, pauses."""
    import numpy as np
    wav = load_mono(req["audio"])
    dur = len(wav) / SR
    db = frames_db(wav)
    peak = float(np.abs(wav).max()) if len(wav) else 0.0
    clip = float((np.abs(wav) > 0.985).mean()) if len(wav) else 0.0
    noise = float(np.percentile(db, 10))
    speech = float(np.percentile(db, 90))
    voiced = float((db > noise + 12).mean())
    rms_db = float(20 * np.log10(np.sqrt((wav ** 2).mean() + 1e-12)))
    issues = []
    if dur < 3:
        issues.append("short")
    if dur > 15:
        issues.append("long")
    if clip > 0.001:
        issues.append("clipping")
    if speech - noise < 25:
        issues.append("noisy")
    if rms_db < -32:
        issues.append("quiet")
    if voiced < 0.45:
        issues.append("pauses")
    score = 100 - 18 * len(issues) - max(0, 30 - (speech - noise))
    return {"seconds": round(dur, 2), "rms_db": round(rms_db, 1), "peak": round(peak, 3), "clipping": round(clip, 4),
            "snr_db": round(speech - noise, 1), "voiced": round(voiced, 2), "issues": issues,
            "score": int(max(5, min(100, score)))}


def _spectral_gate(wav, sr=SR, strength=1.0):
    """Stationary noise reduction: estimate the noise spectrum from the quietest frames and gate it out."""
    import numpy as np
    from scipy.ndimage import uniform_filter
    from scipy.signal import istft, stft
    nper = 1024
    _, _, Z = stft(wav, fs=sr, nperseg=nper, noverlap=nper * 3 // 4)
    mag = np.abs(Z)
    energy = mag.mean(axis=0)
    quiet = mag[:, energy <= np.percentile(energy, 15)]
    if quiet.shape[1] < 3:
        return wav
    noise = quiet.mean(axis=1, keepdims=True)
    mask = np.clip((mag - noise * (1.5 + strength)) / (mag + 1e-9), 0, 1)
    mask = np.maximum(uniform_filter(mask, size=(3, 5)), 0.08)  # smooth; keep a floor so speech isn't hollow
    _, out = istft(Z * mask, fs=sr, nperseg=nper, noverlap=nper * 3 // 4)
    return out[: len(wav)].astype("float32")


def cmd_enhance(req):
    """Clean a voice sample: high-pass, noise reduction, trim/shorten silences, loudness normalisation."""
    import numpy as np
    from scipy.signal import butter, sosfiltfilt
    wav = load_mono(req["audio"])
    wav = sosfiltfilt(butter(4, 70, btype="highpass", fs=SR, output="sos"), wav).astype("float32")
    if req.get("denoise", True):
        wav = _spectral_gate(wav)
    db = frames_db(wav)
    n = int(SR * 0.03)
    voiced = db > max(np.percentile(db, 10) + 10, -55)
    if voiced.any():
        first = max(0, int(np.argmax(voiced)) - 3)
        last = min(len(voiced), len(voiced) - int(np.argmax(voiced[::-1])) + 3)
        keep, gap = [], 0
        for i in range(first, last):  # shorten pauses but keep every word, so the transcript stays valid
            gap = 0 if voiced[i] else gap + 1
            if gap * 0.03 <= 0.35:
                keep.append(wav[i * n:(i + 1) * n])
        wav = np.concatenate(keep) if keep else wav
    wav = wav * (0.1 / np.sqrt((wav ** 2).mean() + 1e-12))  # ≈ −20 dBFS, the level OmniVoice expects
    peak = np.abs(wav).max()
    if peak > 0.89:
        wav = wav * (0.89 / peak)
    f = min(len(wav) // 4, int(SR * 0.01))
    if f > 0:
        wav[:f] *= np.linspace(0, 1, f)
        wav[-f:] *= np.linspace(1, 0, f)
    write_wav(req["out"], wav)
    report = cmd_analyze({"audio": req["out"]})
    report["path"] = req["out"]
    return report


def cmd_unload(req):
    unload_tts()
    unload_stt()
    return {}


COMMANDS = {
    "hello": cmd_hello,
    "transcribe": cmd_transcribe,
    "clone": cmd_clone,
    "synth": cmd_synth,
    "prepare": cmd_prepare,
    "analyze": cmd_analyze,
    "enhance": cmd_enhance,
    "unload": cmd_unload,
}


def main():
    global _current_id
    emit("ready")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            emit("error", msg=f"Bad request: {e}")
            continue
        if req.get("cmd") == "quit":
            break
        _current_id = req.get("id")
        try:
            if "mlx.core" in sys.modules:
                sys.modules["mlx.core"].reset_peak_memory()
            fn = COMMANDS.get(req.get("cmd"))
            if fn is None:
                raise ValueError(T("Unknown command: {cmd}", cmd=req.get("cmd")))
            emit("result", data=fn(req) or {})
            if req.get("low_memory"):
                unload_stt()
        except Exception as e:
            tb = traceback.format_exc()
            print(tb, file=sys.stderr, flush=True)
            msg = str(e) or type(e).__name__
            if "memory" in msg.lower() and "metal" in msg.lower() or "out of memory" in msg.lower():
                msg += T(" — not enough memory: close other apps or choose 4-bit precision.")
            emit("error", msg=f"{type(e).__name__}: {msg}", trace=tb[-4000:])
        finally:
            _current_id = None


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--optimize":
        job = json.loads(sys.argv[2])
        _build_optimized(job["src"], job.get("lora"), int(job["bits"]), job["out"], job.get("domain", "tts"))
        sys.exit(0)
    try:
        main()
    except KeyboardInterrupt:
        pass
