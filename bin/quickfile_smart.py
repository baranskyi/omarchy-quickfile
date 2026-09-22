#!/usr/bin/env python3
"""Dependency-free smart-search plan helpers shared by QuickFile processes.

The optional model only supplies small typed hints.  This module owns the
bounded wire format and the deterministic part of query parsing — keywords,
explicit formats, and the spellings a keyword may take in a file name — so the
main filesystem backend never needs to import torch or transformers.
"""

from __future__ import annotations

import math
import re
import unicodedata
from typing import Any


SMART_PLAN_VERSION = 1
SMART_QUERY_LIMIT = 512
SMART_PLAN_LIMIT = 16 * 1024
SMART_TERM_LIMIT = 8
SMART_TERM_LENGTH_LIMIT = 64
SMART_FORMAT_LIMIT = 4
SMART_KIND_LIMIT = 4
# Measured on the pinned multilingual checkpoint: below 0.75 its hints for
# queries that name no kind or time are mostly noise (a spurious "older" at
# 0.5-0.65, "config" for a lease agreement at 0.5), while correct hints for
# explicit requests land at 0.8-1.0.
SMART_CONFIDENCE_MIN = 0.75

SMART_HINT_VALUES = {
    "target": {"any", "file", "folder"},
    "kind": {
        "any", "document", "code", "config", "image", "audio", "video", "archive",
    },
    "location": {"any", "name", "path", "content"},
    # The rolling windows ("past-week": the last seven days, up to
    # "past-year") and the years come only from the rules; the model is asked
    # for the calendar windows it was measured on (see `questions`).
    "time": {
        "any", "today", "yesterday", "this-week", "last-week", "past-week",
        "this-month", "last-month", "past-month", "past-year", "this-year", "last-year",
        "older",
    },
}
# The hints the model is asked for. Kind is left to the rules: across 50
# probe queries the checkpoint answered it at 0.75-0.99 for requests that
# name no kind at all, and mostly wrongly, while every kind it got right was
# already spelled out.
SMART_MODEL_FIELDS = ("target", "location", "time")

# Formats a user can name by extension, mapped to the broad kind they imply.
SMART_FORMATS = {
    **dict.fromkeys((
        "pdf", "doc", "docx", "odt", "rtf", "txt", "md", "csv", "xls", "xlsx", "ods",
        "ppt", "pptx", "odp", "epub", "tex",
    ), "document"),
    **dict.fromkeys((
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tif", "tiff", "psd",
    ), "image"),
    **dict.fromkeys(("mp3", "wav", "flac", "ogg", "m4a", "opus", "aac"), "audio"),
    **dict.fromkeys(("mp4", "mkv", "mov", "webm", "avi"), "video"),
    **dict.fromkeys(("zip", "tar", "gz", "tgz", "7z", "rar", "xz", "zst"), "archive"),
    **dict.fromkeys(("json", "yaml", "yml", "toml", "ini", "xml", "conf"), "config"),
    **dict.fromkeys((
        "py", "js", "ts", "tsx", "jsx", "sh", "lua", "qml", "rs", "html", "css", "sql",
    ), "code"),
}
# The extensions people write as a bare word ("inventory pdf", "diagram png").
# The others are also ordinary words, names or abbreviations — "md", "opus",
# "avi", "tar", "conf", "rs" (so "rss"), "ts" — and name a format only when
# written with their dot (".md", "*.ts").
_BARE_FORMATS = frozenset((
    "pdf", "docx", "xlsx", "xls", "pptx", "odt", "ods", "odp", "rtf", "csv", "epub", "txt",
    "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "psd", "bmp",
    "mp3", "wav", "flac", "m4a", "aac", "ogg", "mp4", "mkv", "mov", "webm",
    "zip", "rar", "7z", "tgz", "json", "yaml", "yml", "toml", "xml", "html",
))
# Names for a format that are not its extension.
_FORMAT_WORDS = {"пдф": "pdf", "excel": "xlsx", "эксель": "xlsx", "ексель": "xlsx",
                 "markdown": "md"}
# Spellings of one format: asking for a JPG must find photo.jpeg as well, an
# older Office extension stands for the newer one, and a tarball is usually
# compressed.
_FORMAT_EQUIVALENTS = (
    ("jpg", "jpeg"), ("yaml", "yml"), ("tif", "tiff"), ("xls", "xlsx"), ("ppt", "pptx"),
    ("doc", "docx"), ("tar", "tgz", "tar.gz", "tar.xz", "tar.bz2", "tar.zst"),
)


class SmartPlanError(ValueError):
    """Raised when an untrusted smart-search plan violates its wire contract."""


_SEARCH_WORDS = {
    # English query scaffolding, including the verbs that only say what was
    # done to a file ("the config I saved") and never appear in its name.
    # "Change", "update", "edit" and "modify" also name files and folders, so
    # they are read in context (see `_edited_spans`).
    "a", "about", "all", "am", "an", "and", "any", "are", "as", "ask", "asking", "at", "be",
    "been", "by", "called", "can", "created", "did", "do", "downloaded", "file", "files",
    "find", "for", "format", "from", "get", "give", "had", "has", "have", "how", "hunt",
    "hunting", "i", "in", "into", "is", "it", "its", "last", "locate", "look", "looking",
    "looks", "made", "me", "my", "need", "of", "on", "or", "our", "please", "previous",
    "put", "saved", "search", "searching", "show", "some", "something", "that", "the",
    "their", "there", "this", "to", "want", "was", "we", "were", "what", "when", "where",
    "which", "who", "with", "within", "wrote", "you", "your",
    # Russian query scaffolding and common inflections.
    "а", "был", "была", "были", "было", "в", "во", "все", "всё", "где", "дай", "делал",
    "для", "до", "есть", "за", "и", "из", "изменил", "изменял", "или", "ищу", "к", "как",
    "когда", "которого", "которую", "которые", "который", "лежит", "менял", "мне", "мои",
    "мой", "мою", "моя", "на", "найди", "найдите", "найти", "написал", "нашёл", "не",
    "нужен", "нужна", "нужно", "о", "об", "обновил", "от", "отредактировал", "по", "писал",
    "под", "поиск", "покажи", "показать", "поменял", "поправил", "правил", "предыдущая",
    "предыдущего", "предыдущий", "про", "прошлая", "прошлого", "прошлую", "прошлый",
    "редактировал", "с", "скачал", "со", "создал", "сохранил", "течение", "тот", "ту",
    "файл", "файла", "файле", "файлы", "формат", "формате", "что", "эта", "эти", "это",
    "этого", "этой", "этот", "эту", "я",
    # Ukrainian query scaffolding.
    "був", "була", "були", "було", "всі", "відредагував", "де", "до", "з", "завантажив",
    "і", "й", "зберіг", "змінив", "змінював", "знайди", "знайдіть", "знайти", "зі", "коли",
    "мені", "моє", "мої", "мій", "міняв", "написав", "оновив", "писав", "потрібен",
    "потрібна", "потрібно", "пошук", "правив", "протягом", "під", "редагував", "скачав",
    "створив", "та", "той", "у", "файли", "файлу", "файлів", "форматі", "це", "цей", "цю",
    "ця", "ці", "шукай", "шукаю", "що", "яка", "яке", "який", "які", "із",
}

# Words for the kind of entry a query wants. They set hints (see
# `_KIND_PATTERNS`) and never have to appear in a file name.
_CONTROL_WORDS = {
    "archive", "archives", "audio", "code", "config", "configs", "configuration",
    "containing", "contains", "content", "contents", "directory", "document", "documents",
    "folder", "folders", "image", "images", "inside", "latest", "media", "month",
    "monthly", "music", "name", "named", "old", "older", "path", "photo", "photos",
    "picture", "pictures", "podcast", "podcasts", "recent", "recently", "script",
    "scripts", "settings", "source", "today", "video", "videos", "week", "weekly", "year",
    "yesterday",
    "аудио", "видео", "внутри", "вчера", "имени", "имя", "картинок", "код", "контент",
    "месяц", "названии", "настроек", "недавние", "недавний", "недавно", "папок", "путь",
    "свежие", "свежий", "сегодня", "содержит", "содержимое", "содержимом", "старые",
    "старый", "упоминается", "фото", "фоток", "год", "года", "году", "неделя",
    "аудіо", "відео", "вміст", "всередині", "вчора", "зображень", "знімок", "місяць",
    "місяця", "містить", "нещодавні", "нещодавно", "рік", "року", "сьогодні", "старі",
    "тека", "теки", "теку", "тиждень", "тижня",
}

# Longest first. Trimming one common Russian/Ukrainian case or number ending
# lets "графиком" find "график.pdf" and "отпуска" find "отпуск/"; a stem keeps
# at least four letters, and quoted phrases are never trimmed.
_CYRILLIC_ENDINGS = tuple(sorted({
    "иями", "ями", "ами", "ого", "его", "ому", "ему", "ыми", "ими", "ові", "еві",
    "ях", "ах", "ов", "ев", "ів", "ам", "ям", "ом", "ем", "ой", "ей", "ою", "ею",
    "ую", "юю", "ая", "яя", "ые", "ие", "ый", "ий", "ої", "ій",
    "а", "я", "у", "ю", "ы", "и", "і", "ї", "е", "о", "ь", "й",
}, key=len, reverse=True))
_STEM_MIN = 4
# Adjective endings. They also end surnames and first names (Черных, Вадим),
# so they come off only a word long enough that its stem still says something.
_ADJECTIVE_ENDINGS = ("их", "ых", "им", "ым", "ое", "ее")
_ADJECTIVE_STEM_MIN = 5

# Inflected kind words. A word is one of these only when a stem is followed by
# nothing but a case ending ("картинками", "папках"), never by more of a longer
# word: "видеонаблюдение" and "конфигуратор" are topics, not kinds.
_CONTROL_STEMS = re.compile(
    r"(?:фотк|фотографи|картинк|изображени|зображенн|знімк|снимк|папк|документ|архив|архів|музык"
    r"|музик|подкаст|конфиг|конфіг|конфигураци|конфігураці|налаштуванн|настройк|скрипт)"
    r"(?:" + "|".join(_CYRILLIC_ENDINGS) + r")?"
)

_FOLDER_PATTERN = (
    r"\b(?:folders?|director(?:y|ies)|папк(?:а|и|у|е|ой|ах|ами|ам)|папок"
    r"|тек(?:а|и|у|і|ою)|директори[яиюйі]\w*)\b"
)
_FILE_PATTERN = r"\b(?:files?|файл(?:а|е|ы|и|ів|у|ами|ах)?)\b"
# A project and its case endings, not "проектор" or "проектирование".
_PROJECT_PATTERN = (
    r"\b(?:projects?|проект(?:ы|ов|а|у|е|ом|ами|ах|и)?|проєкт(?:и|ів|а|у|і|ом|ами|ах)?)\b"
)
# What someone did to a file: in a file manager that is a file, not the folder
# whose date moved with it.
_EDITED_PATTERN = (
    r"\b(?:(?:по|из)?менял\w*|изменил\w*|поправил\w*|правил|(?:от)?редактировал\w*|обновил\w*"
    r"|змінював|змінив\w*|міняв\w*|правив|(?:від)?редагував\w*|оновив\w*|оновлював\w*)\b"
)
# "Change", "update", "edit" and "modify" also name what a file or folder is
# (CHANGES.md, updated-prices.csv, edit-account.js, a photo editor's Edited
# folder), so they say what someone did only after the one who did it ("the
# config I changed", "what they updated", "what changed") or right before a
# word for the files it was done to ("changed files", "edited today"; see
# `_edited_spans`).
_EDIT_WORD = r"(?:change[sd]?|update[sd]?|edit(?:s|ed)?|modif(?:y|ies|ied))"
_DONE_BY_PATTERN = (
    r"\b(?:i|we|you|they|what)(?:['’](?:ve|s)|\s+(?:did|have|has|had))?\s+"
    + _EDIT_WORD + r"\b"
)
_DONE_TO_WORDS = re.compile(r"\b(?:changed|updated|edited|modified)\b", re.IGNORECASE)

_KIND_PATTERNS = (
    ("config", (
        r"\bconfig(?:uration|s)?\b", r"\bsettings\b", r"\bdotfiles?\b",
        r"\bконфиг(?:и|ов|а|у|е|ами)?\b", r"\bконфигураци(?:я|и|ю|ей|й)\b",
        r"\bнастрой(?:ка|ки|ку|ках|ками|ек)\b", r"\bконфіг(?:и|ів|а|у|ом|ами|ах)?\b",
        r"\bконфігураці(?:я|ї|ю|єю|й)\b", r"\bналаштуван\w*\b",
        r"\.(?:ini|toml|ya?ml|conf|env)\b",
    )),
    ("video", (
        r"\bvideos?\b", r"\bmovies?\b", r"\bscreen\s+recordings?\b",
        r"\b(?:видео|відео)\b", r"\bфил[ьл]м(?:ы|ов|а|у|ом|ами|ах|е)?\b",
        r"\bфільм(?:и|ів|а|у|ом|ами|ах)?\b", r"\bролик(?:и|ов|ів|а|у|ом|ами|ах)?\b",
        r"\bзапис\w*\s+(?:экран|екран)\w*", r"\.(?:mp4|mkv|webm|mov|avi)\b",
    )),
    ("image", (
        r"\bimages?\b", r"\bpictures?\b", r"\bphotos?\b", r"\bscreenshots?\b",
        r"\bфото\b", r"\bфотк\w*\b", r"\bфоток\b", r"\bфотографи\w*\b",
        r"\bизображени\w*\b", r"\bкартин(?:к\w*|ок)\b",
        r"\bскрин(?:ы|ов|ами|ах|а|у|е|ом)?\b", r"\bскриншот\w*\b", r"\bскріншот\w*\b",
        r"\bзображен\w*\b", r"\bзнімк\w*\b", r"\bзнімок\b", r"\bснимк\w*\b", r"\bснимок\b",
        r"\.(?:png|jpe?g|gif|webp|svg|heic)\b",
    )),
    ("audio", (
        r"\baudio\b", r"\bmusic\b", r"\bpodcasts?\b", r"\bsongs?\b",
        r"\bvoice\s+(?:memos?|notes?|messages?|recordings?)\b",
        r"\b(?:аудио|аудіо)\b", r"\bмузык(?:а|и|у|ой|е)\b", r"\bмузик(?:а|и|у|ою|і)\b",
        r"\bподкаст\w*\b", r"\bпесн\w*\b", r"\bпесен\b", r"\bпісн\w*\b", r"\bпісень\b",
        # The adjective of a voice message ("голосовые"), not "голосование"
        # (a vote) or "голосов" (of votes).
        r"\bголосов(?:ой|ая|ое|ые|ых|ую|ого|ому|ым|ыми|ий|а|е|і|их|им|ими|ої|у)\b",
        r"\bдиктофон\w*\b",
        r"\.(?:mp3|flac|wav|ogg|m4a|opus|aac)\b",
    )),
    ("archive", (
        r"\barchives?\b", r"\bархив(?:ы|ов|а|у|е|ом|ами|ах)?\b",
        r"\bархів(?:и|ів|а|у|і|ом|ами|ах)?\b", r"\.(?:zip|tar|gz|bz2|xz|7z|rar|tgz|zst)\b",
    )),
    ("code", (
        r"\bcode\b", r"\bsource\b", r"\bscripts?\b", r"\bкод\b",
        r"\bскрипт(?:ы|ов|а|у|ом|ами|ах|и|ів)?\b",
        r"\.(?:py|js|ts|tsx|jsx|rs|go|java|c|cc|cpp|h|hpp|sh|lua|qml)\b",
    )),
    # A CV, an invoice or a contract is a document whatever it is called, so
    # naming one says "document" as plainly as the word itself does. Reports
    # and guides are left out: as often as not they are HTML, JSON or code.
    ("document", (
        r"\bdocuments?\b", r"\bspreadsheets?\b", r"\bдокумент\w*\b", r"\bтаблиц\w*\b",
        r"\bpresentations?\b", r"\bпрезентаци\w*\b", r"\bпрезентаці\w*\b",
        r"\b(?:resumes?|cvs?|резюме|invoices?|contracts?|agreements?)\b",
        r"\b(?:certificates?|receipts?|letters?)\b",
        r"\bсч[её]т(?:а|у|ом|ов)?\b", r"\bрахун(?:ок|ку|ки|ків|ком|ками)\b",
        r"\bдогов[оі]р\w*\b", r"\bконтракт\w*\b", r"\bписьм(?:о|а|у|ом|е|ами|ах)?\b",
        r"\bсертиф[иі]кат\w*\b", r"\bквитанц\w*\b",
        r"\.(?:pdf|docx?|odt|rtf|txt|md|csv|xlsx?|ods|pptx?)\b",
    )),
)

_LOCATION_PATTERNS = (
    # "Where did we discuss", "the file that says": what is asked about is in
    # the text, so these ask for contents and are not keywords themselves.
    ("content", (
        r"\b(?:content|contents|inside|contains?|containing|mention(?:s|ed|ing)?"
        r"|says|saying|discuss(?:es|ed|ing)?"
        r"|содерж\w*|внутри|контент|упомина\w*|упомянут\w*|говорится|написан\w*"
        r"|обсужда\w*|обсудил\w*"
        r"|вміст\w*|всередині|містит\w*|містять|згаду\w*|згадан\w*|йдеться"
        r"|обговорю\w*|обговорювал\w*|обговорил\w*)\b",
        r"\bгде\s+есть\b", r"\bде\s+є\b",
    )),
    ("path", (r"\b(?:path|пути|путь|шлях\w*)\b",)),
    ("name", (r"\b(?:name|named|called|имя|имени|назв\w*)\b",)),
)

# Phrases that set a calendar window. Their words are spent on the window:
# "на этой неделе" must not leave "недел" behind as a keyword, while a longer
# word that begins like one ("годовщина", "неделимый") is a topic, so the
# nouns are their own case forms only. "Last week" is the calendar week
# before this one, while "the past week", "за последнюю неделю", "за неделю"
# and "the last 7 days" are the seven days up to today, and "the past year"
# the 365. A rolling window of some other length is the shortest of these
# that holds it ("the past 3 days", "the last two weeks", "за последние 3
# месяца", the day before yesterday), and a word for what is recent is the
# past month. Rolling windows come first: the day before yesterday is not
# yesterday.
_FEW = r"few|several|couple\s+of|несколько|кілька|пару"
_DAYS_IN_A_WEEK = (
    r"(?:[2-7]|two|three|four|five|six|seven|" + _FEW
    + r"|два|две|дві|три|четыре|чотири|пять|п['’]ять|шесть|шість|семь|сім)"
)
_DAYS_IN_A_MONTH = r"(?:[89]|[12]\d|30|thirty|тридцать|тридцять)"
_WEEKS_IN_A_MONTH = r"(?:[2-4]|two|three|four|few|два|две|дві|три|четыре|чотири)"
_MONTHS_IN_A_YEAR = (
    r"(?:[2-9]|1[0-2]|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|" + _FEW
    + r"|два|две|дві|три|четыре|чотири|пять|п['’]ять|шесть|шість)"
)
_WEEK = r"(?:недел(?:я|и|е|ю|ей|ь)|тиж(?:день|ня|ні|нів))"
_MONTH = r"(?:месяц(?:а|е|ев)?|місяц(?:ь|я|і|ів))"
_YEAR = r"(?:год|рік)"
_DAYS = r"(?:days|дн(?:я|ей|і|ів)|день)"
_TIME_PATTERNS = (
    ("past-week", (
        r"\b(?:the\s+)?past\s+week\b", r"\bthe\s+last\s+week\b",
        r"\b(?:the\s+)?(?:past|last)\s+" + _DAYS_IN_A_WEEK + r"\s+days\b",
        r"\b(?:the\s+)?day\s+before\s+yesterday\b", r"\bпозавчера\b", r"\bпозавчора\b",
        r"\b(?:последн|останн)\w*\s+(?:" + _WEEK + r"|" + _DAYS_IN_A_WEEK + r"\s+" + _DAYS
        + r")\b",
        r"\bза\s+" + _WEEK + r"\b",
    )),
    ("past-year", (
        r"\b(?:the\s+)?past\s+year\b", r"\bthe\s+last\s+year\b",
        r"\b(?:the\s+)?(?:past|last)\s+" + _MONTHS_IN_A_YEAR + r"\s+months\b",
        r"\b(?:последн|останн)\w*\s+(?:" + _YEAR + r"|" + _MONTHS_IN_A_YEAR + r"\s+" + _MONTH
        + r")\b",
    )),
    ("past-month", (
        r"\b(?:the\s+)?past\s+month\b", r"\bthe\s+last\s+month\b",
        r"\b(?:the\s+)?(?:past|last)\s+" + _DAYS_IN_A_MONTH + r"\s+days\b",
        r"\b(?:the\s+)?(?:past|last)\s+" + _WEEKS_IN_A_MONTH + r"\s+weeks\b",
        r"\b(?:последн|останн)\w*\s+(?:" + _MONTH + r"|" + _DAYS_IN_A_MONTH + r"\s+" + _DAYS
        + r"|" + _WEEKS_IN_A_MONTH + r"\s+" + _WEEK + r")\b",
        r"\b(?:recent|recently|latest|newest)\b", r"\bнедавн\w*\b", r"\bнещодавн\w*\b",
        r"\bсвеж(?:ий|ая|ее|ие|их)\b", r"\bсвіж(?:ий|а|е|і|их)\b",
        r"\bпоследн(?:ие|ий|яя|ее|их)\b", r"\bостанн(?:і|ій|я|є|іх)\b",
    )),
    ("yesterday", (
        r"\byesterday\b", r"\bвчера\b", r"\bвчерашн\w*\b", r"\bвчора\b", r"\bвчорашн\w*\b",
    )),
    ("today", (
        r"\btoday\b", r"\btonight\b", r"\bthis\s+(?:morning|afternoon|evening)\b",
        r"\bсегодня\b", r"\bсегодняшн\w*\b", r"\bсьогодні\b", r"\bсьогоднішн\w*\b",
    )),
    ("last-week", (
        r"\b(?:last|previous)\s+week\b", r"\b(?:прошл|минул)\w*\s+" + _WEEK + r"\b",
    )),
    ("this-week", (
        r"\bthis\s+week\b", r"\bэт\w*\s+" + _WEEK + r"\b",
        r"\bц(?:ього|ей|ьому|ю)\s+" + _WEEK + r"\b",
    )),
    ("last-month", (
        r"\b(?:last|previous)\s+month\b", r"\b(?:прошл|минул)\w*\s+" + _MONTH + r"\b",
    )),
    ("this-month", (
        r"\bthis\s+month\b", r"\bэт\w*\s+" + _MONTH + r"\b",
        r"\bц(?:ього|ей|ьому)\s+" + _MONTH + r"\b",
    )),
    ("this-year", (
        r"\bthis\s+year\b", r"\bэт\w*\s+год(?:а|у)?\b", r"\bц(?:ього|ей|ьому)\s+р(?:оку|ік|оці)\b",
    )),
    ("last-year", (
        r"\b(?:last|previous)\s+year\b", r"\bпрошл\w*\s+год(?:а|у)?\b",
        r"\bминул\w*\s+р(?:ік|оку|оці)\b",
    )),
    # Whole adjective forms only: a bare "стар" prefix would also match
    # "стартапы" and turn a topic word into a date filter.
    ("older", (
        r"\bold(?:er)?\b",
        r"\bстар(?:ый|ая|ое|ые|ых|ого|ой|ую|ым|ыми|ий|а|е|і|их|ої|ими)\b",
    )),
)

# Words for what a file is, as people name it in one language while the file
# was named in another, often by the program that made it: a contract is
# "agreement.pdf" whatever word the search uses, a Ukrainian "рахунок" is an
# invoice, and a screenshot is named in the desktop's language. Only
# nouns for kinds of documents and recordings — never topics or names — and
# the first word of each group names it.
_VOCABULARY = (
    ("resume", "cv", "резюме"),
    ("contract", "agreement", "договор", "договір", "контракт", "угода"),
    ("invoice", "счёт", "рахунок", "инвойс", "інвойс"),
    ("receipt", "чек", "квитанция", "квитанція"),
    ("letter", "письмо", "лист"),
    ("report", "отчёт", "звіт"),
    ("certificate", "сертификат", "сертифікат"),
    ("presentation", "slides", "deck", "презентация", "презентація"),
    ("instruction", "manual", "guide", "инструкция", "інструкція"),
    ("notes", "заметки", "нотатки"),
    ("meeting", "встреча", "совещание", "зустріч", "нарада"),
    ("recording", "запись", "запис"),
    ("screenshot", "скриншот", "скріншот", "скрин"),
    ("screen", "экран", "екран"),
    ("project", "проект", "проєкт"),
)
# Words that are one of a group's only when another of its words is typed: a
# Ukrainian letter is a "лист", but typed, "лист" is as often a Russian sheet
# ("лист бюджета") as a letter.
_VOCABULARY_ONE_WAY = frozenset({"лист"})
# Words for what a file is outweigh words for what it is about: in "Zorb
# contract" the file named agreement.pdf is the answer, not every file that
# mentions Zorb.
_DOCUMENT_GROUPS = {
    "resume", "contract", "invoice", "receipt", "letter", "report", "certificate",
    "presentation", "instruction",
}
SMART_DOCUMENT_WEIGHT = 1.2
# Words an entry's type can say without its name: a phone screenshot is
# IMG_0042.PNG, a call recording "GMT20260102-093000.m4a", and in a file
# manager a project is a folder. Such an entry has the word at the grade of a
# matching folder, so the ones named with it still rank first. These words
# frame a request more than they narrow it, so they weigh less.
_TYPE_GROUPS = {
    "screenshot": frozenset({"image"}),
    "recording": frozenset({"audio", "video"}),
    "project": frozenset({"folder"}),
}
SMART_TYPE_WORD_WEIGHT = 0.5
# In a file manager a project is a folder, and what someone changed is a file
# (a folder's date moves whenever a file in it is added), but both words are
# weaker evidence than "folder" and "file" themselves: "project brief" is a
# file.
SMART_IMPLIED_TARGET_CONFIDENCE = 0.6
# Month names, as typed or as their stems, with the English name and the
# number a date in a file name spells them with: "march" finds 2024/03/ and
# scan_20240312.pdf. Only a month's own case forms count, so
# Мартин and Августина are names, not months. English "may" is a month only
# when written as one, "May".
_MONTH_ENDINGS = r"(?:ь|я|е|ю|ем|ём)?"
_MONTHS = (
    ("01", "january", r"январ" + _MONTH_ENDINGS + r"|січ(?:ень|ен|н[яі]?)"),
    ("02", "february", r"феврал" + _MONTH_ENDINGS + r"|лют(?:ий|и|ого|ог|ому|ом)"),
    ("03", "march", r"март(?:а|е|у|ом)?|берез(?:ень|ен|н[яі]?)"),
    ("04", "april", r"апрел" + _MONTH_ENDINGS + r"|квіт(?:ень|ен|н[яі]?)"),
    ("05", "may", r"ма[йяе]|трав(?:ень|ен|н[яі]?)"),
    ("06", "june", r"июн" + _MONTH_ENDINGS + r"|черв(?:ень|ен|н[яі]?)"),
    ("07", "july", r"июл" + _MONTH_ENDINGS + r"|лип(?:ень|ен|н[яі]?)"),
    ("08", "august", r"август(?:а|е|у|ом)?|серп(?:ень|ен|н[яі]?)"),
    ("09", "september", r"сентябр" + _MONTH_ENDINGS + r"|верес(?:ень|ен|н[яі]?)"),
    ("10", "october", r"октябр" + _MONTH_ENDINGS + r"|жовт(?:ень|ен|н[яі]?)"),
    ("11", "november", r"ноябр" + _MONTH_ENDINGS + r"|листопад(?:а|і|у|ом)?"),
    ("12", "december", r"декабр" + _MONTH_ENDINGS + r"|груд(?:ень|ен|н[яі]?)"),
)
# How much a spelling that is not the typed word counts: an equivalent word
# or English singular is nearly as good, a transliteration is an
# approximation, and that of a word typed short and in lower case, which is
# as often another word ("мост" is not most), less than text that has the
# word itself (see `SmartTerm`).
SMART_EQUIVALENT_FACTOR = 0.95
SMART_TRANSLITERATION_FACTOR = 0.85
SMART_SHORT_TRANSLITERATION_FACTOR = 0.3
SMART_TRANSLITERATION_MIN = 5
# A typed word of five letters or more may be misspelt by one letter
# ("calender"). A name is only compared with it when it has the word's first
# three letters, which keeps the check to a substring test for almost every
# name.
SMART_TYPO_MIN = 5
SMART_TYPO_PROBE = 3
# Inside a longer word ("handler" in "requestHandler"), a typed word counts
# only from this length: shorter ones sit inside unrelated words by chance
# ("port" in "report", "rover" in "controversy").
SMART_INFIX_MIN = 6

# Case folding for matching. Russian and Ukrainian spell the same words with
# different letters, so і/ї/ы/й fold to и, є/э/ё to е and ґ to г, soft signs
# disappear, and a doubled letter counts once ("програма" is Russian
# "программа"); accents go too, so "résumé" is "resume". An apostrophe
# between letters is part of its word and folds away with the hard sign it
# stands for: "м'ясо", "мʼясо" and "мясо", "об'єкт" and "объект",
# "D'Artagnan" and "Dartagnan" are one spelling.
_FOLD = str.maketrans({
    "є": "е", "э": "е", "і": "и", "ы": "и", "ґ": "г", "ь": None, "ъ": None,
})
_COMBINING_MARKS = re.compile(r"[\u0300-\u036f]")
_CYRILLIC_DOUBLE = re.compile(r"([а-я])\1+")
_APOSTROPHES = "'\u2019\u02bc"
_INNER_APOSTROPHE = re.compile(r"(?<=[^\W\d_])['\u2019\u02bc](?=[^\W\d_])")
# One Latin spelling for both scripts: Cyrillic is transliterated, and the
# Latin letters that transliterations disagree on are merged, so "Харкові"
# meets "Kharkiv". It is only ever compared across scripts: "wine" is not
# "vine".
_LATIN = str.maketrans({
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "zh", "з": "z",
    "и": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
    "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch",
    "ш": "sh", "щ": "shch", "ю": "iu", "я": "ia", "y": "i", "w": "v", "q": "k",
    "x": "ks",
})
# A Latin c sounds as s before e/i/y and as k elsewhere, except in "ch",
# which is how ч is transliterated.
_SOFT_C = re.compile(r"c(?=[eiy])")
_HARD_C = re.compile(r"c(?!h)")
_DOUBLE_LETTER = re.compile(r"([a-z])\1+")
_VOWELS = re.compile(r"[aeiouyаеиоуюя]")
# Words borrowed from English keep its sounds, not its letters: "дж" is the
# "j" of jazz/джаз, as English "dg" is before e or i, ю after a consonant is
# the "u" of computer/компьютер, "ци" the "ti" of position/позиция, з the "s"
# of present/презентация, and "ph" and "th" are the ф of graph and the т of
# method.
_LOANWORD_SOUNDS = re.compile(r"дж|(?<=[бвгдзклмнпрстфхцчшщ])ю")
_LOANWORD_LETTERS = re.compile(r"ph|th|dg(?=[ei])|tsi(?=[aeiou]|$)|z(?!h)")
_LOANWORD_SPELLINGS = {
    "дж": "j", "ю": "u", "ph": "f", "th": "t", "dg": "j", "tsi": "ti", "z": "s",
}
_CAMEL_BOUNDARY = re.compile(
    r"(?<=[a-zà-ÿа-яёіїєґ])(?=[A-ZÀ-ÞА-ЯЁІЇЄҐ])|(?<=[A-Z])(?=[A-Z][a-z])"
)
_TOKEN = re.compile(r"[^\W\d_]+|\d+")
# Scripts written without spaces between words: a name there is one long
# "word", so a keyword matches anywhere inside it.
_UNSPACED = re.compile(
    r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u0e00-\u0e7f]"
)


def _fold_letters(value: str) -> str:
    """`fold_text` without merging doubled letters."""
    folded = value.casefold()
    if "'" in folded or "\u2019" in folded or "\u02bc" in folded:
        folded = _INNER_APOSTROPHE.sub("", folded)
    if folded.isascii():
        return folded
    return _COMBINING_MARKS.sub("", unicodedata.normalize("NFKD", folded)).translate(_FOLD)


def fold_text(value: str) -> str:
    """Casefold and merge the spellings that differ only between alphabets."""
    folded = _fold_letters(value)
    return folded if folded.isascii() else _CYRILLIC_DOUBLE.sub(r"\1", folded)


def _loanword_spelling(match: re.Match[str]) -> str:
    return _LOANWORD_SPELLINGS[match.group(0)]


def _latin(folded: str) -> str:
    latin = _HARD_C.sub("k", _SOFT_C.sub("s", folded)).translate(_LATIN)
    return _DOUBLE_LETTER.sub(r"\1", _LOANWORD_LETTERS.sub(_loanword_spelling, latin))


def latin_keys(folded: str) -> tuple[str, ...]:
    """Map already folded text to its approximate Latin spellings: Cyrillic
    as transliterated and, where that differs, as spelled by a word borrowed
    from English. Both count, as a name keeps its transliteration: "Зорбюк"
    is Zorbiuk, while "компьютер" is computer."""
    plain = _latin(folded)
    if folded.isascii():
        return (plain,)
    borrowed = _latin(_LOANWORD_SOUNDS.sub(_loanword_spelling, folded))
    return (plain,) if borrowed == plain else (plain, borrowed)


def stop_word(word: str) -> bool:
    """Whether a folded word only frames a request ("and", "про")."""
    return word in _SEARCH_WORDS


def text_script(folded: str) -> str:
    """"cyrillic", "latin" or "" for folded text, by its first letter of either."""
    for char in folded:
        if "а" <= char <= "я":
            return "cyrillic"
        if "a" <= char <= "z":
            return "latin"
    return ""


def unspaced(text: str) -> bool:
    return _UNSPACED.search(text) is not None


def name_words(name: str) -> tuple[list[str], list[str]]:
    """Folded words of a file name, and the extra words its camelCase humps
    make ("MoonHarbor" is "moonharbor", and also "moon" and "harbor")."""
    words = _TOKEN.findall(fold_text(name))
    split = _CAMEL_BOUNDARY.sub(" ", name)
    humps = _TOKEN.findall(fold_text(split)) if split != name else []
    return words, humps


def _normal_text(value: str) -> str:
    return " ".join(str(value or "").strip().split())


def _hint(value: str = "any", confidence: float = 1.0, source: str = "rule") -> dict[str, Any]:
    amount = float(confidence)
    if not math.isfinite(amount):
        amount = 0.0
    return {
        "value": value,
        "confidence": round(max(0.0, min(1.0, amount)), 4),
        "source": source,
    }


def _bounded(query: str) -> str:
    return _normal_text(query)[:SMART_QUERY_LIMIT]


def _blank(text: str, spans: list[tuple[int, int]]) -> str:
    characters = list(text)
    for start, end in spans:
        characters[start:end] = " " * (end - start)
    return "".join(characters)


def _quoted(text: str) -> tuple[list[str], str]:
    """Quoted phrases, and the text with them blanked. A quoted phrase is
    searched verbatim and never read as a hint or a format, so it keeps its
    quotes as a keyword (see `SmartTerm`). An apostrophe inside a word
    ("Alice's", "м'ята") opens or closes nothing."""
    phrases: list[str] = []
    spans: list[tuple[int, int]] = []
    for match in re.finditer(r'"([^"\n]+)"|(?<!\w)\'([^\'\n]+)\'(?!\w)', text):
        value = _normal_text(match.group(1) or match.group(2) or "")
        if value:
            phrases.append(f'"{value[:SMART_TERM_LENGTH_LIMIT - 2]}"')
        spans.append(match.span())
    return phrases, _blank(text, spans)


def _phrase_spans(pattern: str, text: str) -> list[tuple[int, int]]:
    """Where a hint pattern occurs, except inside a dotted file name:
    "notes.old" is a name, not a request for old notes."""
    spans: list[tuple[int, int]] = []
    for match in re.finditer(pattern, text, re.IGNORECASE):
        start, end = match.span()
        if not pattern.startswith(r"\.") and (
                text[start - 1:start] == "." or re.match(r"\.\w", text[end:end + 2])):
            continue
        spans.append((start, end))
    return spans


def _says(patterns: tuple[str, ...], text: str) -> bool:
    return any(_phrase_spans(pattern, text) for pattern in patterns)


# Each kind's words as one pattern: a request for a kind asks it of every folder.
_KIND_WORDS = tuple(
    (kind, re.compile(
        "|".join(f"(?:{pattern})" for pattern in patterns if not pattern.startswith(r"\.")),
        re.IGNORECASE,
    ))
    for kind, patterns in _KIND_PATTERNS
)


def word_kind(word: str) -> str:
    """The kind a single word names ("photos", "скрипты", "Videos"), if any."""
    for kind, pattern in _KIND_WORDS:
        if pattern.fullmatch(word):
            return kind
    return ""


def _format_of(word: str) -> str:
    """The format one bare query word names: "pdf", "pngs" or "excel"."""
    folded = word.casefold()
    if folded in _FORMAT_WORDS:
        return _FORMAT_WORDS[folded]
    if folded in _BARE_FORMATS:
        return folded
    if folded.endswith("s") and folded[:-1] in _BARE_FORMATS:
        return folded[:-1]
    return ""


def _scaffolding(word: str) -> bool:
    folded = word.casefold()
    return (folded in _SEARCH_WORDS or folded in _CONTROL_WORDS
            or _CONTROL_STEMS.fullmatch(folded) is not None)


# A word of a query: letters and digits with the dots, dashes and symbols of
# a file name or a language ("site-backup.tar.gz", "C++"), and an apostrophe
# between letters ("м'ясо", "D'Artagnan"). An English possessive is the word
# it follows ("Alice's").
_WORD = r"[^\W_](?:[\w.+#@-]|(?<=[^\W\d_])['\u2019](?=[^\W\d_]))*"
_POSSESSIVE = re.compile(r"(?<=[a-zA-Z])['\u2019]s$")
_QUERY_TOKEN = re.compile(r"(?:\*?\.)?" + _WORD)
# Words that make two formats a conversion ("mp4 to gif", "heic в jpg") and
# words for what something is for ("tools for pdf"): formats there are topics.
# After a verb of searching, "for" says what is searched for ("looking for
# pdf", "search for png images"), and the format is asked for.
_CONVERSION_WORDS = frozenset({"to", "into", "в", "у"})
_PURPOSE_WORDS = frozenset({"for", "для"})
_SEARCH_VERBS = frozenset({
    "look", "looks", "looking", "search", "searching", "hunt", "hunting", "ask", "asking",
})
# Words that join kinds a query asks for alike: "photos and videos".
_KIND_JOINS = frozenset({"and", "or", "&", "+", ",", "и", "или", "та", "і", "й", "або", "чи"})


def _bare_formats(text: str) -> list[tuple[int, int, str]]:
    """The bare format words of an unquoted query that ask for a format.

    A bare format word does unless it describes another word — "csv parser",
    "json-server", "mp4 to gif", "tools for pdf" — rather than the file
    wanted: it is directly followed by a topic word (and not preceded by a
    kind word it agrees with, as in "презентация pptx с отчётом"), is part of
    a hyphenated compound with a topic word, one side of a conversion, or
    what something is for. Such a word stays a keyword. Hyphenated to a word
    for its own kind ("pdf-документ") it names the format.
    """
    tokens = list(_QUERY_TOKEN.finditer(text))
    words = [token.group(0).rstrip(".") for token in tokens]
    found: list[tuple[int, int, str]] = []
    for index, word in enumerate(words):
        if word.startswith(("*.", ".")):
            continue
        parts = [part for part in word.split("-") if part]
        named = [part for part in parts if _format_of(part)]
        if len(named) != 1:
            continue
        value = _format_of(named[0])
        kind = SMART_FORMATS[value]
        if any(part not in named and not _scaffolding(part) and word_kind(part) != kind
               for part in parts):
            continue
        following = words[index + 1] if index + 1 < len(words) else ""
        preceding = words[index - 1] if index else ""
        described = (following and not _scaffolding(following)
                     and not _format_of(following) and word_kind(following) != kind)
        if described and word_kind(preceding) != kind:
            continue
        converted = (
            following.casefold() in _CONVERSION_WORDS and index + 2 < len(words)
            and _format_of(words[index + 2])
        ) or (
            preceding.casefold() in _CONVERSION_WORDS and index >= 2
            and _format_of(words[index - 2])
        )
        purpose = preceding.casefold() in _PURPOSE_WORDS and not (
            index >= 2 and words[index - 2].casefold() in _SEARCH_VERBS)
        if converted or purpose:
            continue
        found.append((*tokens[index].span(), value))
    return found


def _named_kinds(text: str) -> list[str]:
    """The kinds an unquoted query asks for by name, the main one first.

    A kind is named by a kind word or by a bare format word that asks for a
    format ("zip" for an archive). The kind named first is the one asked for,
    as in "видео с музыкой", "mp4 with music" or "script for photos"; the
    rest describe it. Two English nouns side by side are a compound whose
    head comes last: a "photo archive" is an archive. Kinds joined by "and",
    "и" or "та" are all asked for: "photos and videos".
    """
    mentions = sorted([
        (*span, kind)
        for kind, patterns in _KIND_PATTERNS for pattern in patterns
        for span in _phrase_spans(pattern, text)
    ] + [(start, end, SMART_FORMATS[value]) for start, end, value in _bare_formats(text)])
    if not mentions:
        return []
    start, end, kind = mentions[0]
    index = 1
    while index < len(mentions):
        later_start, later_end, later_kind = mentions[index]
        if later_start >= end:
            if text[end:later_start].strip(" -") or not text[start:later_end].isascii():
                break
            end, kind = later_end, later_kind
        index += 1
    kinds = [kind]
    for later_start, later_end, later_kind in mentions[index:]:
        if later_start < end:
            continue
        joins = text[end:later_start].replace(",", " , ").split()
        if not joins or any(word.casefold() not in _KIND_JOINS for word in joins):
            break
        if later_kind not in kinds:
            kinds.append(later_kind)
        end = later_end
    return kinds[:SMART_KIND_LIMIT]


def _formats(text: str) -> tuple[list[str], list[tuple[int, int]]]:
    """The formats an unquoted query asks for, in the order named, and the
    words that asked. ".md" and "*.png" always name a format; a bare format
    word does when it asks for one (see `_bare_formats`) of a kind the query
    asks for: in "screenshot of a pdf", "pdf" is a topic."""
    kinds = _named_kinds(text)
    found: list[tuple[int, int, str]] = []
    for token in _QUERY_TOKEN.finditer(text):
        word = token.group(0).rstrip(".")
        if word.startswith(("*.", ".")):
            # ".tar.gz" asks for what its last extension says.
            value = word.lstrip("*.").casefold().rsplit(".", 1)[-1]
            if value in SMART_FORMATS:
                found.append((*token.span(), value))
    found.extend(
        item for item in _bare_formats(text) if not kinds or SMART_FORMATS[item[2]] in kinds
    )
    formats: list[str] = []
    spans: list[tuple[int, int]] = []
    for start, end, value in sorted(found):
        spans.append((start, end))
        if value not in formats and len(formats) < SMART_FORMAT_LIMIT:
            formats.append(value)
    return formats, spans


def extract_formats(query: str) -> list[str]:
    """Return the file formats a query names explicitly, in the order named."""
    return _formats(_quoted(_bounded(query))[1])[0]


def extract_kinds(query: str) -> list[str]:
    """Return the kinds a query asks for by name, the one in its kind hint first."""
    return _named_kinds(_quoted(_bounded(query))[1])


def format_suffixes(formats: list[str]) -> tuple[str, ...]:
    """Every file-name ending that satisfies the requested formats."""
    suffixes: set[str] = set()
    for value in formats:
        suffixes.add(value)
        for spellings in _FORMAT_EQUIVALENTS:
            if value in spellings:
                suffixes.update(spellings)
    return tuple(sorted("." + suffix for suffix in suffixes))


def _edited_spans(text: str) -> list[tuple[int, int]]:
    """Where a query says what someone did to a file (see `_DONE_BY_PATTERN`)."""
    spans = _phrase_spans(_EDITED_PATTERN, text) + _phrase_spans(_DONE_BY_PATTERN, text)
    for match in _DONE_TO_WORDS.finditer(text):
        following = re.match(r"\s+(" + _WORD + ")", text[match.end():])
        if following and _scaffolding(following.group(1).rstrip(".")):
            spans.append(match.span())
    return spans


def rule_hints(query: str) -> dict[str, dict[str, Any]]:
    """Return explicit bilingual hints without making any probabilistic guesses."""
    text = _quoted(_bounded(query))[1]
    hints = {key: _hint() for key in SMART_HINT_VALUES}

    if _says((_FOLDER_PATTERN,), text):
        hints["target"] = _hint("folder")
    elif _says((_FILE_PATTERN,), text):
        hints["target"] = _hint("file")
    elif _says((_PROJECT_PATTERN,), text):
        hints["target"] = _hint("folder", SMART_IMPLIED_TARGET_CONFIDENCE)
    elif _edited_spans(text):
        hints["target"] = _hint("file", SMART_IMPLIED_TARGET_CONFIDENCE)

    kinds = _named_kinds(text)
    kind = kinds[0] if kinds else ""
    if not kind:
        formats = _formats(text)[0]
        kind = SMART_FORMATS[formats[0]] if formats else ""
    if kind:
        hints["kind"] = _hint(kind)

    for value, patterns in _LOCATION_PATTERNS:
        if _says(patterns, text):
            hints["location"] = _hint(value)
            break

    for value, patterns in _TIME_PATTERNS:
        if _says(patterns, text):
            hints["time"] = _hint(value)
            break
    return hints


def _inflection_stem(term: str) -> str:
    """Trim one Russian/Ukrainian ending; other scripts stay as typed.

    English plurals are not trimmed here — "iOS" is not the plural of
    "iO" — but matched as spellings of the word (see `SmartTerm`). An
    apostrophe inside the word counts for no letter ("п'ятниця").
    """
    letters = _INNER_APOSTROPHE.sub("", term)
    if not letters.isalpha():
        return term
    folded = letters.casefold()
    if re.fullmatch(r"[а-яёіїєґ]+", folded):
        for ending in _ADJECTIVE_ENDINGS:
            if folded.endswith(ending) and len(letters) - len(ending) >= _ADJECTIVE_STEM_MIN:
                return term[:-len(ending)].rstrip(_APOSTROPHES)
        for ending in _CYRILLIC_ENDINGS:
            if folded.endswith(ending) and len(letters) - len(ending) >= _STEM_MIN:
                return term[:-len(ending)].rstrip(_APOSTROPHES)
    return term


def _term_words(query: str) -> list[tuple[str, str]]:
    """The bounded keywords of a query, each with the word typed for it."""
    phrases, text = _quoted(_bounded(query))
    terms = [(phrase, phrase) for phrase in phrases]
    # Hint phrases are spent on their hints, and a format asked for is a
    # format, not a word the name must contain.
    spans = _formats(text)[1] + _edited_spans(text)
    for patterns in (
        (_FOLDER_PATTERN, _FILE_PATTERN),
        *(patterns for _value, patterns in _LOCATION_PATTERNS),
        *(patterns for _value, patterns in _TIME_PATTERNS),
    ):
        for pattern in patterns:
            spans.extend(_phrase_spans(pattern, text))
    for raw in re.findall(_WORD, _blank(text, spans)):
        # A sentence's full stop is not part of its last word.
        word = _POSSESSIVE.sub("", raw.rstrip(".-_@"))
        folded = word.casefold()
        if not folded or _scaffolding(folded):
            continue
        if len(folded) == 1 and not folded.isdigit() and not unspaced(folded):
            continue
        terms.append((_inflection_stem(word)[:SMART_TERM_LENGTH_LIMIT], word))
    unique: list[tuple[str, str]] = []
    seen: set[str] = set()
    for term, word in terms:
        key = term.casefold()
        if key in seen:
            continue
        seen.add(key)
        unique.append((term, word))
        if len(unique) >= SMART_TERM_LIMIT:
            break
    return unique


def extract_terms(query: str) -> list[str]:
    """Extract bounded lexical terms while preserving explicit quoted phrases."""
    return [term for term, _word in _term_words(query)]


def typed_words(query: str) -> dict[str, str]:
    """The word a query typed for each of its keywords, by the keyword in
    lower case: "квартиру" for "квартир"."""
    return {term.casefold(): word for term, word in _term_words(query)}


def _english_singulars(word: str) -> list[str]:
    """Singular spellings of an English plural, for matching only."""
    if not re.fullmatch(r"[a-z]{4,}", word) or word.endswith(("ss", "us", "is")):
        return []
    if word.endswith("ies"):
        # "stories" is a story, "cookies" a cookie: both spellings are kept.
        return [word[:-3] + "y", word[:-1]]
    if word.endswith(("ches", "shes", "sses", "xes")):
        return [word[:-2], word[:-1]]
    return [word[:-1]] if word.endswith("s") else []


def _plural_stem(word: str) -> str:
    """"agency" becomes "agenc" so it also meets "agencies"."""
    if re.fullmatch(r"[a-z]{5,}y", word) and word[-2] not in "aeiou":
        return word[:-1]
    return ""


def _fleeting_vowel(word: str) -> str:
    """"книжок" is a form of "книжка": in a final -ек/-ок the vowel drops in
    every other form ("книжки", "станка"), so a word with it also meets the
    forms without it."""
    folded = word.casefold()
    if re.fullmatch(r"[а-яёіїєґ]{3,}[еоё]к", folded):
        return folded[:-2] + "к"
    return ""


# Case endings as `fold_text` spells them, and none at all. A word too short
# to trim ("дачи", "моря", "игрой") keeps its ending as a keyword, and meets
# the other forms of its word as its three-letter stem and one of these — a
# noun's: "Алла" is not "алая".
_FOLDED_ENDINGS = frozenset({""} | {fold_text(ending) for ending in _CYRILLIC_ENDINGS})
SMART_NOUN_ENDINGS = tuple(
    ending for ending in _CYRILLIC_ENDINGS
    if ending not in {"ого", "его", "ому", "ему", "ыми", "ими", "ая", "яя", "ые", "ие",
                      "ый", "ий", "ій", "ої", "ую", "юю"}
)
_FOLDED_NOUN_ENDINGS = frozenset({""} | {fold_text(ending) for ending in SMART_NOUN_ENDINGS})


def _short_stem(folded: str) -> str:
    """The three-letter stem of a short inflected Russian or Ukrainian word:
    "дач" of "дачи", which `_inflection_stem` leaves whole."""
    if re.fullmatch(r"[а-я]{4,6}", folded) and folded[3:] in _FOLDED_ENDINGS:
        return folded[:3]
    return ""


def _doubled_stem(word: str) -> str:
    """The stem of a short Russian or Ukrainian word that folding shortened
    by merging a doubled letter: "Анна" folds to "ана", which may no longer
    run on into any three letters ("анализ", "ананас"), only into a case
    ending of "анн" ("Анны"). "" for any other word."""
    lower = word.casefold()
    if not re.fullmatch(r"[а-яёіїєґ]+", lower):
        return ""
    folded = fold_text(lower)
    if folded == _fold_letters(lower) or _extension(len(folded), 4) is None:
        return ""
    return lower[:3] if len(lower) > 3 and fold_text(lower[3:]) in _FOLDED_ENDINGS else lower


def inflected(word: str, stem: str) -> bool:
    """Whether a folded word is a short stem with a case ending ("дача")."""
    return word.startswith(stem) and word[len(stem):] in _FOLDED_NOUN_ENDINGS


def _word_forms(word: str) -> set[str]:
    """The folded forms that decide whether a word is one of the vocabulary's."""
    folded = fold_text(word)
    forms = {fold_text(_inflection_stem(word)), folded, *_english_singulars(folded)}
    fleeting = _fleeting_vowel(word)
    if fleeting:
        forms.add(fold_text(fleeting))
    return forms


_VOCABULARY_FORMS = tuple(
    (group[0], group, set().union(*(
        _word_forms(word) for word in group if word not in _VOCABULARY_ONE_WAY
    )))
    for group in _VOCABULARY
)


def _vocabulary_group(word: str) -> tuple[str, tuple[str, ...]] | None:
    """The vocabulary group a keyword is a form of, if any. The keyword has to
    be one of the group's words with at most one case or number ending —
    "invoices", "рахунку", "договору" — never a longer word that happens to
    begin like one ("projections", "записки", "contractor")."""
    forms = _word_forms(word)
    for name, words, members in _VOCABULARY_FORMS:
        if forms & members:
            return name, words
    return None


def _extension(length: int, loose: int) -> int | None:
    """How many letters a word may add to a form and still match it: any
    number from `loose` letters on, an ending's worth one letter shorter, and
    none below that — "tax" finds "taxes" but not "taxonomy", "cv" only "cv"."""
    if length >= loose:
        return None
    return 3 if length == loose - 1 else 0


# A file name typed with its extension is still that file's name when the
# extension on disk is a spelling of the same format ("ledger.xls" is
# ledger.xlsx, "backup.tgz" backup.tar.gz), and its name alone still names
# a file of any extension, as a word start counts.
_EXTENSION_SPELLINGS = frozenset(SMART_FORMATS) | frozenset(
    spelling for spellings in _FORMAT_EQUIVALENTS for spelling in spellings
)
SMART_DOTTED_NAME_FACTOR = 0.9


def _dotted_names(text: str) -> list[tuple[str, float]]:
    """The other spellings of a name typed with its extension, as folded runs
    of words, and how much each counts."""
    parts = text.casefold().split(".")
    for cut in range(1, len(parts)):
        extension = ".".join(parts[cut:])
        if extension in _EXTENSION_SPELLINGS:
            break
    else:
        return []
    name = " ".join(_TOKEN.findall(fold_text(".".join(parts[:cut]))))
    if not name:
        return []
    names = [
        (f"{name} {spelling.replace('.', ' ')}", SMART_EQUIVALENT_FACTOR)
        for spellings in _FORMAT_EQUIVALENTS if extension in spellings
        for spelling in spellings if spelling != extension
    ]
    return names + [(name, SMART_DOTTED_NAME_FACTOR)]


class SmartTerm:
    """One keyword and every spelling it may take in a name or a file.

    `forms` holds (text, factor, extension, infix, typed): the folded
    spelling, how much a match on it counts, how many letters a longer word
    may add to it (None for any, 0 for whole words only; see `_extension`),
    whether it may match inside a word, and whether it counts only for the
    entries of `spelled_types` and the folders that hold them: "запись" is a
    recording only when it names one, so a translation of "recording" does
    not find a doctor's appointment. `latin` holds the same for the Latin
    spelling, compared only with words of the other script, and `stem` the
    letters of a short Russian or Ukrainian word that meet its case forms.
    `word` is the word the query typed, of which `text` may be the stem.
    `symbols` is set instead for a keyword that is its symbols — "!!!", "@",
    "C++", "C#" — which is looked for as typed. A keyword the query quoted
    comes in its quotes and is matched only as typed.
    """

    def __init__(self, text: str, word: str = "") -> None:
        quoted = len(text) > 2 and text[0] == text[-1] == '"'
        if quoted:
            text = text[1:-1].strip()
        self.text = text
        folded = " ".join(_TOKEN.findall(fold_text(text)))
        self.folded = folded
        self.weight = 1.0
        self.group = ""
        # Entry types that carry the word without their name ("image" for a
        # screenshot); cleared by `smart_terms` when the word is all there is.
        # The word's translations name only entries of these types, cleared
        # or not.
        self.types: frozenset[str] = frozenset()
        self.spelled_types: frozenset[str] = frozenset()
        # The kind of media the query names with this word ("voice memo"):
        # every file of that kind is a candidate for it (see `smart_terms`).
        self.media = ""
        # The two-digit number of a month the keyword names ("09" for
        # "march"), matched only where a date spells it.
        self.month = ""
        self.typo = ""
        self.stem = ""
        self.symbols = ""
        self.script = text_script(folded)
        self.forms: list[tuple[str, float, int | None, bool, bool]] = []
        self.latin: list[tuple[str, float, int | None]] = []
        self.content_forms: list[str] = []
        # One letter and a "+" or "#" is a language, not the letter.
        if not folded or (len(folded) == 1 and folded.isalpha() and re.search(r"[+#]", text)):
            self.symbols = text.casefold().strip()
            return
        whole = unspaced(folded)
        # Shorter text is inside too many words to say anything, except in a
        # script without spaces, where two characters are a word. Text is
        # compared in lower case, as rg compares it: a casefolded "straße" is
        # "strasse", which rg would never find in "Straße".
        in_text = len(text) >= 3 or whole
        if quoted:
            # Whole words, as a quoted phrase is a run of them.
            self.forms.append((folded, 1.0, None if whole else 0, whole, False))
            if in_text:
                self._add_content(text.lower())
            return
        doubled = _doubled_stem(text)
        self._add(folded, 1.0, own=True, whole=whole, loose=not doubled)
        for name, factor in _dotted_names(text):
            self._add(name, factor, own=False, loose=False)
        if len(folded) >= SMART_TYPO_MIN and folded.isalpha():
            self.typo = folded
        self.stem = fold_text(doubled) if doubled else _short_stem(folded)
        singulars = _english_singulars(folded)
        for singular in singulars:
            # "cats" meets "cat", but a word as short as that does not run on
            # into "catch".
            self._add(singular, SMART_EQUIVALENT_FACTOR, own=len(singular) >= 4)
        fleeting = _fleeting_vowel(text)
        if fleeting:
            self._add(fold_text(fleeting), SMART_EQUIVALENT_FACTOR, own=True)
            self._add_content(fleeting)
        group = _vocabulary_group(text) if " " not in folded else None
        if group is not None:
            name, words = group
            self.group = name
            if name in _DOCUMENT_GROUPS:
                self.weight = SMART_DOCUMENT_WEIGHT
            elif name in _TYPE_GROUPS:
                self.weight = SMART_TYPE_WORD_WEIGHT
                self.types = self.spelled_types = _TYPE_GROUPS[name]
            typed = bool(self.types)
            for word in words:
                key = fold_text(_inflection_stem(word))
                self._add(key, SMART_EQUIVALENT_FACTOR, own=False, typed=typed)
                stem = _plural_stem(word)
                if stem:
                    self._add(stem, SMART_EQUIVALENT_FACTOR, own=False, typed=typed)
                if len(word) >= 4:
                    self._add_content(_inflection_stem(word).lower())
        for number, english, pattern in _MONTHS:
            month = (folded == english and (english != "may" or text[:1] == "M")
                     or re.fullmatch(pattern, text.casefold()))
            if month:
                self._add(english, SMART_EQUIVALENT_FACTOR, own=False)
                self.month = number
                break
        if self.script and " " not in folded:
            # How far a Latin word may run on is decided by the typed word, as
            # for its own spelling: "чек" is a check, never a checkout, and a
            # short stem adds at most an ending of two letters, not the rest
            # of a longer word. A word typed short and in lower case is as
            # often a common word, which meets only the same word or its
            # plural, and one of three letters only when it has no vowel, as
            # an abbreviation such as "смс" has none; a capitalised one is a
            # name.
            extension = _extension(len(folded), SMART_TRANSLITERATION_MIN)
            factor = SMART_TRANSLITERATION_FACTOR
            short = len(fold_text(word or text)) < SMART_TRANSLITERATION_MIN
            named = text[:1].isupper()
            if short and not named:
                extension, factor = 1, SMART_SHORT_TRANSLITERATION_FACTOR
            if not short or named or len(folded) > 3 or not _VOWELS.search(folded):
                self.latin.extend(
                    (latin, factor, None if extension is None else min(extension, 2))
                    for latin in latin_keys(folded) if len(latin) >= 3
                )
        if in_text:
            self._add_content(doubled or text.lower())
        for singular in singulars:
            self._add_content(singular)

    def _add(
        self, form: str, factor: float, *, own: bool, whole: bool = False,
        loose: bool = True, typed: bool = False,
    ) -> None:
        if not form or any(existing[0] == form for existing in self.forms):
            return
        if whole:
            self.forms.append((form, factor, None, True, typed))
            return
        # A derived spelling has to be longer than a typed word before it may
        # match loosely.
        extension = _extension(len(form), 4 if own else 5) if loose else 0
        infix = loose and own and len(form) >= SMART_INFIX_MIN
        self.forms.append((form, factor, extension, infix, typed))

    def _add_content(self, form: str) -> None:
        if form and form not in self.content_forms:
            self.content_forms.append(form)


def within_one_edit(first: str, second: str) -> bool:
    """Whether two different words differ by one letter changed, added or
    dropped, or by two neighbouring letters swapped."""
    if first == second or abs(len(first) - len(second)) > 1:
        return False
    start = 0
    while start < min(len(first), len(second)) and first[start] == second[start]:
        start += 1
    if len(first) == len(second):
        rest = first[start + 1:] == second[start + 1:]
        swapped = (first[start:start + 2] == second[start:start + 2][::-1]
                   and first[start + 2:] == second[start + 2:])
        return rest or swapped
    longer, shorter = (first, second) if len(first) > len(second) else (second, first)
    return longer[start + 1:] == shorter[start:]


# Kinds of media, which cameras, phones and recorders name by number and date
# rather than by what they hold.
_MEDIA_KINDS = frozenset({"image", "audio", "video"})


def media_words(query: str) -> dict[str, str]:
    """The keywords of a query that name a kind of media, with that kind.

    "Voice memo", "songs", "movies": any file of the kind says these words,
    whatever a device called it, as an image says "screenshot".
    """
    text = _quoted(_bounded(query))[1]
    words: dict[str, str] = {}
    for kind, patterns in _KIND_PATTERNS:
        if kind not in _MEDIA_KINDS:
            continue
        for pattern in patterns:
            if pattern.startswith(r"\."):
                continue
            for start, end in _phrase_spans(pattern, text):
                for raw in re.findall(_WORD, text[start:end]):
                    words.setdefault(_inflection_stem(raw).casefold(), kind)
    return words


def spent_words(query: str) -> list[tuple[str, str]]:
    """The words a query spent on hints that also name things, each with the
    kind it names: a kind it asks for ("config", "фото", "photos") and what
    someone did to a file ("edited", with no kind). They are not keywords a
    row needs, but a name or a folder that says one (config.toml, photos/,
    Edited/) is named for what the query asks — a kind word only for an entry
    of that kind: a JPG named video-still.jpg is not a video."""
    text = _quoted(_bounded(query))[1]
    spans = [
        span for _kind, patterns in _KIND_PATTERNS for pattern in patterns
        if not pattern.startswith(r"\.") for span in _phrase_spans(pattern, text)
    ] + _edited_spans(text)
    words: list[tuple[str, str]] = []
    for start, end in sorted(spans):
        for raw in re.findall(_WORD, text[start:end]):
            word = _inflection_stem(raw)
            kind = word_kind(raw) if _scaffolding(raw) else ""
            named = kind or re.fullmatch(_EDIT_WORD, raw, re.IGNORECASE)
            if named and word.casefold() not in (known.casefold() for known, _ in words):
                words.append((word[:SMART_TERM_LENGTH_LIMIT], kind))
    return words[:SMART_TERM_LIMIT]


def smart_terms(
    terms: list[str], filtered: bool, media: dict[str, str] | None = None,
    typed: dict[str, str] | None = None,
) -> list[SmartTerm]:
    """Analyse plan terms. `media` maps the keywords that name a kind of media
    to it (see `media_words`), and `typed` each keyword to the word typed for
    it (see `typed_words`). A word an entry's type can say ("screenshots",
    "проект") is satisfied by that type only beside other keywords or a kind,
    date or format (`filtered`): alone, "мои проекты" asks for projects by
    name, not for every folder. Only a word that names media makes every file
    of the kind a candidate: "запись" is as often an entry or an appointment
    as a recording, so an audio file says it only when something else in the
    query finds that file."""
    analysed = [SmartTerm(term, (typed or {}).get(term.casefold(), "")) for term in terms]
    analysed = [term for term in analysed if term.forms or term.symbols]
    for term in analysed:
        kind = (media or {}).get(term.text.casefold())
        if kind:
            term.types = term.types | {kind}
            term.media = kind
            term.weight = min(term.weight, SMART_TYPE_WORD_WEIGHT)
    if not filtered and all(term.types for term in analysed):
        for term in analysed:
            term.types = frozenset()
            term.media = ""
            term.weight = 1.0
    for term in analysed:
        # A screenshot is not found by the word in someone's notes: a word its
        # type says is looked for in names only.
        if term.types:
            term.content_forms = []
    return analysed


def fallback_plan(query: str, request_id: int | None = None) -> dict[str, Any]:
    normalized = _bounded(query)
    plan: dict[str, Any] = {
        "version": SMART_PLAN_VERSION,
        "terms": extract_terms(normalized),
        "formats": extract_formats(normalized),
        "kinds": extract_kinds(normalized),
        "hints": rule_hints(normalized),
    }
    if request_id is not None:
        plan["requestId"] = int(request_id)
    return plan


def merge_laya_answers(plan: dict[str, Any], answers: Any) -> dict[str, Any]:
    """Fill rule-free model-field hint slots from an untrusted Laya answer mapping."""
    merged = validate_plan(plan)
    if not isinstance(answers, dict):
        return merged
    for field in SMART_MODEL_FIELDS:
        allowed = SMART_HINT_VALUES[field]
        current = merged["hints"][field]
        if current["value"] != "any":
            continue
        answer = answers.get(field)
        if not isinstance(answer, dict):
            continue
        choice = str(answer.get("choice", ""))
        if choice not in allowed:
            continue
        try:
            confidence = float(answer.get("confidence", 0.0))
        except (TypeError, ValueError):
            confidence = 0.0
        if not math.isfinite(confidence) or confidence < SMART_CONFIDENCE_MIN:
            continue
        merged["hints"][field] = _hint(choice, confidence, "laya")
    return merged


def validate_plan(plan: Any) -> dict[str, Any]:
    """Return a normalized plan or reject malformed/oversized untrusted input."""
    if not isinstance(plan, dict) or plan.get("version") != SMART_PLAN_VERSION:
        raise SmartPlanError("unsupported smart-search plan")
    raw_terms = plan.get("terms", [])
    if not isinstance(raw_terms, list) or len(raw_terms) > SMART_TERM_LIMIT:
        raise SmartPlanError("smart-search terms are invalid")
    terms: list[str] = []
    for raw in raw_terms:
        if not isinstance(raw, str):
            raise SmartPlanError("smart-search term must be text")
        value = _normal_text(raw)
        if not value or len(value) > SMART_TERM_LENGTH_LIMIT or "\x00" in value:
            raise SmartPlanError("smart-search term has an invalid value")
        terms.append(value)

    # Optional: a plan from before formats existed simply names none.
    raw_formats = plan.get("formats", [])
    if not isinstance(raw_formats, list) or len(raw_formats) > SMART_FORMAT_LIMIT:
        raise SmartPlanError("smart-search formats are invalid")
    formats: list[str] = []
    for raw in raw_formats:
        if not isinstance(raw, str) or raw not in SMART_FORMATS:
            raise SmartPlanError("smart-search format is unsupported")
        if raw not in formats:
            formats.append(raw)

    # Optional too: every kind the query asks for by name ("photos and
    # videos"), the one in the kind hint first.
    raw_kinds = plan.get("kinds", [])
    if not isinstance(raw_kinds, list) or len(raw_kinds) > SMART_KIND_LIMIT:
        raise SmartPlanError("smart-search kinds are invalid")
    kinds: list[str] = []
    for raw in raw_kinds:
        if not isinstance(raw, str) or raw == "any" or raw not in SMART_HINT_VALUES["kind"]:
            raise SmartPlanError("smart-search kind is unsupported")
        if raw not in kinds:
            kinds.append(raw)

    raw_hints = plan.get("hints", {})
    if not isinstance(raw_hints, dict):
        raise SmartPlanError("smart-search hints are invalid")
    hints: dict[str, dict[str, Any]] = {}
    for field, allowed in SMART_HINT_VALUES.items():
        raw = raw_hints.get(field, {"value": "any", "confidence": 0.0, "source": "rule"})
        if not isinstance(raw, dict):
            raise SmartPlanError(f"smart-search {field} hint is invalid")
        value = raw.get("value", "any")
        source = raw.get("source", "rule")
        if value not in allowed or source not in {"rule", "laya"}:
            raise SmartPlanError(f"smart-search {field} hint is unsupported")
        try:
            confidence = float(raw.get("confidence", 0.0))
        except (TypeError, ValueError) as exc:
            raise SmartPlanError(f"smart-search {field} confidence is invalid") from exc
        if not 0.0 <= confidence <= 1.0:
            raise SmartPlanError(f"smart-search {field} confidence is out of range")
        hints[field] = _hint(str(value), confidence, str(source))
    normalized: dict[str, Any] = {
        "version": SMART_PLAN_VERSION,
        "terms": terms,
        "formats": formats,
        "kinds": kinds,
        "hints": hints,
    }
    request_id = plan.get("requestId")
    if isinstance(request_id, int) and not isinstance(request_id, bool) and request_id >= 0:
        normalized["requestId"] = request_id
    model = plan.get("model")
    if isinstance(model, str) and 0 < len(model) <= 64:
        normalized["model"] = model
    device = plan.get("device")
    if isinstance(device, str) and 0 < len(device) <= 32:
        normalized["device"] = device
    latency = plan.get("latencyMs")
    if isinstance(latency, (int, float)) and not isinstance(latency, bool):
        latency_value = float(latency)
        if math.isfinite(latency_value):
            normalized["latencyMs"] = max(0, min(60000, round(latency_value)))
    return normalized


def questions() -> dict[str, dict[str, Any]]:
    """The fixed low-cardinality decision schema, one question per model field."""
    return {
        "target": {
            "type": "choice",
            "instructions": "Does the user ask for files, folders, or either?",
            "criteria": {
                "any": "No explicit preference, or both files and folders",
                "file": "Regular files rather than directories",
                "folder": "Directories or folders rather than regular files",
            },
        },
        "location": {
            "type": "choice",
            "instructions": "Where does the user expect the search text to match?",
            "criteria": {
                "any": "No preference between name, path, and contents",
                "name": "The file or folder name",
                "path": "The relative filesystem path",
                "content": "Text inside a file",
            },
        },
        "time": {
            "type": "choice",
            "instructions": "Which modification-time window does the request specify?",
            "criteria": {
                "any": "No modification-time condition",
                "today": "Modified today",
                "yesterday": "Modified yesterday",
                "this-week": "Modified during the current calendar week",
                "last-week": "Modified during the previous calendar week",
                "this-month": "Modified during the current calendar month",
                "last-month": "Modified during the previous calendar month",
                "older": "Older than the start of the previous calendar month",
            },
        },
    }
